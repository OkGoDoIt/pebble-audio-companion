using System.ComponentModel;
using System.Text.Json.Nodes;
using Microsoft.EntityFrameworkCore;
using ModelContextProtocol.Protocol;
using ModelContextProtocol.Server;
using PebbleAudio.Server.Sync;

namespace PebbleAudio.Server.Mcp;

/// <summary>
/// <c>get_audio</c>: a clip of a conversation through the phone (<see cref="PhoneRequestService"/>). The server keeps
/// no audio until one is asked for; then the phone uploads the span on its next sync and a job converts it, never
/// this call.
/// </summary>
[McpServerToolType]
public sealed class AudioTools
{
	/// <summary>The <c>_meta</c> key widgets read the playable link from (docs/tool-results.md).</summary>
	public const string MetaKey = "pebbleaudio/audio";

	[McpServerTool(
		Name = "get_audio",
		Title = "Get audio",
		ReadOnly = true,
		Destructive = false,
		Idempotent = true,
		OpenWorld = false,
		UseStructuredContent = true,
		OutputSchemaType = typeof(AudioResult))]
	[McpMeta("openai/toolInvocation/invoking", "Getting the audio…")]
	[McpMeta("openai/toolInvocation/invoked", "Got the audio")]
	[Description(
		"A short-lived link to play a stretch of a conversation, only when the person asks to hear it. If the server " +
		"does not have it yet, it asks the phone and answers requested: the phone uploads it on its next sync (usually " +
		"within minutes while it is recording; it may be out of reach), so ask again later. Never use it to answer a " +
		"text question.")]
	public static async Task<CallToolResult> GetAudio(
		RequestContext<CallToolRequestParams> context,
		ArchiveReader archive,
		PhoneRequestService requests,
		[Description("The conversation's id.")] string conversation_id,
		[Description("Where to start: an RFC 3339 time or seconds from the conversation's start. Default: its start.")] string? start = null,
		[Description("Where to end: an RFC 3339 time or seconds from the conversation's start. Default: the longest clip the server allows.")] string? end = null,
		CancellationToken cancellationToken = default)
	{
		var call = await archive.BeginAsync(context.User, cancellationToken);
		var id = conversation_id.Trim();
		var conversation = await archive.Conversations(call).SingleOrDefaultAsync(c => c.Id == id, cancellationToken);
		if (conversation is null)
		{
			await archive.LogAsync(call, "get_audio", [], cancellationToken);
			return ToolResults.Of(Unavailable(id, "notFound", "I could not find that conversation in what you share.", null, null));
		}

		var zone = LogicalDays.Zone(conversation.TimeZone);
		var from = conversation.StartedAt;
		if (!string.IsNullOrWhiteSpace(start) && !Days.TryParseTime(start, conversation.StartedAt, zone, out from))
		{
			return ToolResults.Error(ConversationTools.TimeHelp("start"));
		}

		var until = from + call.Settings.ClipMaxDuration;
		if (!string.IsNullOrWhiteSpace(end) && !Days.TryParseTime(end, conversation.StartedAt, zone, out until))
		{
			return ToolResults.Error(ConversationTools.TimeHelp("end"));
		}

		ClipRequestResult clip;
		try
		{
			clip = await requests.RequestClipAsync(call.UserId, id, from, until, cancellationToken);
		}
		catch (ArgumentOutOfRangeException)
		{
			var ended = conversation.EndedAt is { } e ? Speak.Clock(Days.Local(e, zone)) : "now";
			return ToolResults.Error($"That span holds none of the conversation, which runs from {Speak.Clock(Days.Local(conversation.StartedAt, zone))} to {ended}.");
		}

		var title = ArchiveReader.Blank(conversation.Title);
		var named = title ?? "the conversation";
		var spanStart = Days.Local(clip.StartAt, zone);
		var spanEnd = Days.Local(clip.EndAt, zone);
		var url = clip.StartAt is { } at ? archive.Links.Moment(id, Days.Offset(at, conversation.StartedAt)) : archive.Links.Conversation(id);
		var span = spanStart is { } s && spanEnd is { } e2 ? $" from {Speak.Clock(s)} to {Speak.Clock(e2)}" : "";
		var lost = clip.Gaps.Select(g => new LostSpanOut(Days.Local(g.StartedAt, zone), Days.Local(g.EndedAt, zone), Days.Minutes(g.EndedAt - g.StartedAt))).ToList();

		AudioResult result;
		JsonObject? meta = null;
		switch (clip.Outcome)
		{
			case ClipOutcome.Ready when clip.Link is { } link:
				result = new AudioResult(
					$"The clip is ready: {Speak.Clause(named)}{span}." + (lost.Count > 0 ? $" {Speak.Duration(lost.Sum(l => l.Minutes))} of it was lost." : ""),
					"ready",
					null,
					id,
					title,
					url,
					spanStart,
					spanEnd,
					link.Url,
					Days.Local(link.ExpiresAt, zone),
					Days.Local(clip.CoveredStartAt, zone),
					Days.Local(clip.CoveredEndAt, zone),
					clip.DurationMs is { } ms ? Days.Minutes(ms) : clip.CoveredStartAt is { } cs && clip.CoveredEndAt is { } ce ? Days.Minutes(ce - cs) : null,
					lost,
					clip.RequestId,
					null);
				meta = new JsonObject
				{
					[MetaKey] = new JsonObject
					{
						["url"] = link.Url,
						["expiresAt"] = SyncJson.Format(link.ExpiresAt),
						["mimeType"] = "audio/mp4",
						["conversationId"] = id,
						["startedAt"] = clip.CoveredStartAt is { } covered ? SyncJson.Format(covered) : clip.StartAt is { } asked ? SyncJson.Format(asked) : null,
						["endedAt"] = clip.CoveredEndAt is { } coveredEnd ? SyncJson.Format(coveredEnd) : clip.EndAt is { } askedEnd ? SyncJson.Format(askedEnd) : null,
					},
				};
				break;
			case ClipOutcome.Ready:
			case ClipOutcome.Waiting:
				result = new AudioResult(
					$"I asked your phone for {Speak.Clause(named)}{span}. It usually arrives within a few minutes while the phone is recording; ask again shortly.",
					"requested",
					null,
					id,
					title,
					url,
					spanStart,
					spanEnd,
					null,
					null,
					null,
					null,
					null,
					[],
					clip.RequestId,
					Days.Local(clip.WaitingUntil, zone));
				break;
			case ClipOutcome.NotAllowed:
				result = new AudioResult(
					"You haven't allowed assistants to play your audio. You can allow it in Pebble Audio on your iPhone.",
					"notAllowed",
					null,
					id,
					title,
					url,
					null,
					null,
					null,
					null,
					null,
					null,
					null,
					[],
					null,
					null);
				break;
			case ClipOutcome.Unavailable:
				result = Unavailable(id, "gone", $"Your phone no longer has the audio of {Speak.Clause(named)}.", title, url) with { StartedAt = spanStart, EndedAt = spanEnd, RequestId = clip.RequestId };
				break;
			case ClipOutcome.Failed:
				result = Unavailable(id, "failed", $"The clip of {Speak.Clause(named)} could not be made.", title, url) with { StartedAt = spanStart, EndedAt = spanEnd, RequestId = clip.RequestId };
				break;
			case ClipOutcome.NotDelivered:
				result = Unavailable(id, "notDelivered", $"Your phone did not send the clip of {Speak.Clause(named)} in time; it may be off or out of reach.", title, url) with { StartedAt = spanStart, EndedAt = spanEnd, RequestId = clip.RequestId };
				break;
			case ClipOutcome.NotFound:
			default:
				result = Unavailable(id, "notFound", "I could not find that conversation in what you share.", title, url);
				break;
		}

		await archive.LogAsync(call, "get_audio", [id], cancellationToken);
		return ToolResults.Of(result, meta);
	}

	private static AudioResult Unavailable(string id, string reason, string summary, string? title, string? url) =>
		new(summary, "unavailable", reason, id, title, url, null, null, null, null, null, null, null, [], null, null);
}
