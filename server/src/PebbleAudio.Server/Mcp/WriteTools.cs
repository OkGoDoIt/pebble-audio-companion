using System.ComponentModel;
using Microsoft.EntityFrameworkCore;
using ModelContextProtocol.Protocol;
using ModelContextProtocol.Server;
using PebbleAudio.Server.Data;
using PebbleAudio.Server.Sync;

namespace PebbleAudio.Server.Mcp;

/// <summary>
/// The write tools: <c>create_follow_up</c> (which adds a reminder), <c>update_follow_up</c>, and <c>create_note</c>. They need the
/// <c>archive:write</c> scope (<see cref="Auth.McpScopeFilters"/> hides and refuses them without it) and the person's
/// permission on the phone (<c>edits</c>); a write is stored here at once and travels to the phone, which stays the
/// system of record.
/// </summary>
[McpServerToolType]
public sealed class WriteTools
{
	public const string NotAllowedSummary =
		"You haven't allowed assistants to add to your archive. You can allow it in Pebble Audio on your iPhone.";

	private const string OnItsWay = "It reaches your phone on its next sync.";

	private const string NotFoundSummary = "I could not find that reminder or follow-up in what you share.";

	[McpServerTool(
		Name = "create_follow_up",
		Title = "Add a reminder",
		ReadOnly = false,
		Destructive = false,
		Idempotent = false,
		OpenWorld = false,
		UseStructuredContent = true,
		OutputSchemaType = typeof(FollowUpWriteResult))]
	[McpMeta("openai/toolInvocation/invoking", "Adding the reminder…")]
	[McpMeta("openai/toolInvocation/invoked", "Added the reminder")]
	[Description(
		"Adds a reminder to the person's list, in their archive and on their phone. Only when the person asks for it; " +
		"confirm what you added. Link it to where it was said with source_conversation_id and source_at when there " +
		"is such a moment.")]
	public static async Task<CallToolResult> CreateFollowUp(
		RequestContext<CallToolRequestParams> context,
		ArchiveReader archive,
		PhoneRequestService requests,
		[Description("What to do, as the person would write it.")] string text,
		[Description("Why it matters.")] string? why = null,
		[Description("The words it came from, if any.")] string? quote = null,
		[Description("When it is due: an RFC 3339 time.")] string? due_at = null,
		[Description("low, normal (default), or high.")] string? priority = null,
		[Description("The conversation it was said in.")] string? source_conversation_id = null,
		[Description("When in that conversation: an RFC 3339 time or seconds from its start.")] string? source_at = null,
		CancellationToken cancellationToken = default)
	{
		var call = await archive.BeginAsync(context.User, cancellationToken);
		if (string.IsNullOrWhiteSpace(text))
		{
			return ToolResults.Error("A reminder needs text.");
		}

		DateTimeOffset? due = null;
		if (!string.IsNullOrWhiteSpace(due_at))
		{
			if (!Days.TryParseTime(due_at, call.Now, call.Zone, out var at) || IsNumber(due_at))
			{
				return ToolResults.Error("due_at is an RFC 3339 time, for example 2026-10-16T18:00:00+07:00.");
			}

			due = at;
		}

		var level = priority?.Trim().ToLowerInvariant() switch
		{
			null or "" or "normal" => 1,
			"low" => 0,
			"high" => 2,
			_ => -1,
		};
		if (level < 0)
		{
			return ToolResults.Error("priority is low, normal, or high.");
		}

		if (!(await requests.GetPreferencesAsync(call.UserId, cancellationToken)).Edits)
		{
			return await AnswerAsync(archive, call, "create_follow_up", new FollowUpWriteResult(NotAllowedSummary, "notAllowed", null, null), [], cancellationToken);
		}

		Conversation? source = null;
		DateTimeOffset? sourceAt = null;
		if (ArchiveReader.Blank(source_conversation_id) is { } sourceId)
		{
			source = await archive.Conversations(call).SingleOrDefaultAsync(c => c.Id == sourceId, cancellationToken);
			if (source is null)
			{
				return await AnswerAsync(archive, call, "create_follow_up", new FollowUpWriteResult("I could not find that conversation in what you share, so nothing was added.", "notFound", null, null), [], cancellationToken);
			}

			if (!string.IsNullOrWhiteSpace(source_at))
			{
				if (!Days.TryParseTime(source_at, source.StartedAt, LogicalDays.Zone(source.TimeZone), out var at))
				{
					return ToolResults.Error(ConversationTools.TimeHelp("source_at"));
				}

				sourceAt = at;
			}
		}

		var written = await requests.CreateFollowUpAsync(
			call.UserId,
			new FollowUpDraft(text.Trim(), ArchiveReader.Blank(quote), ArchiveReader.Blank(why), due, level, source?.Id, sourceAt),
			cancellationToken);
		FollowUpWriteResult result;
		switch (written.Outcome)
		{
			case PhoneWriteOutcome.Queued:
				var followUp = await Shape(archive, call, written.Item!, cancellationToken);
				result = new FollowUpWriteResult($"Added a reminder: {Speak.Clause(followUp.Text)}. {OnItsWay}", "added", followUp, written.RequestId);
				break;
			case PhoneWriteOutcome.NotAllowed:
				result = new FollowUpWriteResult(NotAllowedSummary, "notAllowed", null, null);
				break;
			default:
				result = new FollowUpWriteResult("Nothing was added.", "notFound", null, null);
				break;
		}

		return await AnswerAsync(archive, call, "create_follow_up", result, written.Item is { } item ? [item.Id] : [], cancellationToken);
	}

	[McpServerTool(
		Name = "update_follow_up",
		Title = "Change a reminder",
		ReadOnly = false,
		// It replaces the text, due date, and snooze and can archive: not an additive change, so hosts ask first.
		Destructive = true,
		Idempotent = true,
		OpenWorld = false,
		UseStructuredContent = true,
		OutputSchemaType = typeof(FollowUpWriteResult))]
	[McpMeta("openai/toolInvocation/invoking", "Updating the reminder…")]
	[McpMeta("openai/toolInvocation/invoked", "Updated the reminder")]
	[Description(
		"Marks a reminder done or not done, edits its text, sets or clears its due date or snooze, or archives it. For " +
		"a follow-up waiting for review, stage reminder adds it to the person's reminders and stage skipped skips it: " +
		"only when the person says so, never on your own judgment. Only when the person asks for it; confirm what " +
		"changed. A field left out stays as it is.")]
	public static async Task<CallToolResult> UpdateFollowUp(
		RequestContext<CallToolRequestParams> context,
		ArchiveReader archive,
		PhoneRequestService requests,
		[Description("The reminder's or follow-up's id, as list_follow_ups gives it.")] string id,
		[Description("True to mark it done, false to reopen it.")] bool? done = null,
		[Description("New text.")] string? text = null,
		[Description("A new due time (RFC 3339), or none to clear it.")] string? due_at = null,
		[Description("Snooze until this time (RFC 3339), or none to wake it.")] string? snoozed_until = null,
		[Description("True to archive it, false to bring it back.")] bool? archived = null,
		[Description("reminder (the person said yes to it) or skipped (they said no).")] string? stage = null,
		CancellationToken cancellationToken = default)
	{
		var call = await archive.BeginAsync(context.User, cancellationToken);
		if (!TryOptionalTime(due_at, call, out var due) || !TryOptionalTime(snoozed_until, call, out var snooze))
		{
			return ToolResults.Error("due_at and snoozed_until are RFC 3339 times, or none to clear them.");
		}

		FollowUpStage? newStage = stage?.Trim().ToLowerInvariant() switch
		{
			null or "" => null,
			"reminder" => FollowUpStage.Reminder,
			"skipped" or "skip" => FollowUpStage.Skipped,
			_ => FollowUpStage.Suggested,
		};
		if (newStage == FollowUpStage.Suggested)
		{
			return ToolResults.Error("stage is reminder or skipped.");
		}

		if (!(await requests.GetPreferencesAsync(call.UserId, cancellationToken)).Edits)
		{
			return await AnswerAsync(archive, call, "update_follow_up", new FollowUpWriteResult(NotAllowedSummary, "notAllowed", null, null), [], cancellationToken);
		}

		var followUpId = id.Trim();
		if (!await archive.FollowUps(call).AnyAsync(f => f.Id == followUpId, cancellationToken))
		{
			return await AnswerAsync(archive, call, "update_follow_up", new FollowUpWriteResult(NotFoundSummary, "notFound", null, null), [], cancellationToken);
		}

		var change = new FollowUpChange
		{
			Done = done,
			Text = ArchiveReader.Blank(text),
			DueAt = due,
			SnoozedUntil = snooze,
			ArchivedAt = archived switch
			{
				true => new Settable<DateTimeOffset?>(call.Now),
				false => new Settable<DateTimeOffset?>(null),
				null => null,
			},
			Stage = newStage,
		};
		var written = await requests.UpdateFollowUpAsync(call.UserId, followUpId, change, cancellationToken);
		FollowUpWriteResult result;
		switch (written.Outcome)
		{
			case PhoneWriteOutcome.Queued:
			case PhoneWriteOutcome.Unchanged:
				var followUp = await Shape(archive, call, written.Item!, cancellationToken);
				var what = Speak.Clause(followUp.Text);
				var summary = written.Outcome == PhoneWriteOutcome.Unchanged ? $"Nothing changed: {what}."
					: done == true ? $"Marked done: {what}. {OnItsWay}"
					: archived == true ? $"Archived: {what}. {OnItsWay}"
					: newStage == FollowUpStage.Reminder ? $"Added to your reminders: {what}. {OnItsWay}"
					: newStage == FollowUpStage.Skipped ? $"Skipped: {what}. {OnItsWay}"
					: $"Updated the reminder: {what}. {OnItsWay}";
				result = new FollowUpWriteResult(summary, written.Outcome == PhoneWriteOutcome.Unchanged ? "unchanged" : "updated", followUp, written.RequestId);
				break;
			case PhoneWriteOutcome.NotAllowed:
				result = new FollowUpWriteResult(NotAllowedSummary, "notAllowed", null, null);
				break;
			default:
				result = new FollowUpWriteResult(NotFoundSummary, "notFound", null, null);
				break;
		}

		return await AnswerAsync(archive, call, "update_follow_up", result, [followUpId], cancellationToken);
	}

	[McpServerTool(
		Name = "create_note",
		Title = "Add a note",
		ReadOnly = false,
		Destructive = false,
		Idempotent = false,
		OpenWorld = false,
		UseStructuredContent = true,
		OutputSchemaType = typeof(NoteWriteResult))]
	[McpMeta("openai/toolInvocation/invoking", "Adding the note…")]
	[McpMeta("openai/toolInvocation/invoked", "Added the note")]
	[Description(
		"Adds a note to a conversation in the person's archive and on their phone, for example meeting notes they ask " +
		"for. Only when the person asks for it; confirm what you added. Cite the moments it draws on.")]
	public static async Task<CallToolResult> CreateNote(
		RequestContext<CallToolRequestParams> context,
		ArchiveReader archive,
		PhoneRequestService requests,
		[Description("The conversation the note is about.")] string conversation_id,
		[Description("The note's text.")] string body,
		[Description("A short title.")] string? title = null,
		[Description("Moments it draws on: at (an RFC 3339 time or seconds from the conversation's start) and an optional end_at.")] CitationArgument[]? citations = null,
		CancellationToken cancellationToken = default)
	{
		var call = await archive.BeginAsync(context.User, cancellationToken);
		if (string.IsNullOrWhiteSpace(body) && string.IsNullOrWhiteSpace(title))
		{
			return ToolResults.Error("A note needs a body.");
		}

		if (!(await requests.GetPreferencesAsync(call.UserId, cancellationToken)).Edits)
		{
			return await AnswerAsync(archive, call, "create_note", new NoteWriteResult(NotAllowedSummary, "notAllowed", null, null), [], cancellationToken);
		}

		var conversationId = conversation_id.Trim();
		var conversation = await archive.Conversations(call).SingleOrDefaultAsync(c => c.Id == conversationId, cancellationToken);
		if (conversation is null)
		{
			return await AnswerAsync(archive, call, "create_note", new NoteWriteResult("I could not find that conversation in what you share, so nothing was added.", "notFound", null, null), [], cancellationToken);
		}

		var zone = LogicalDays.Zone(conversation.TimeZone);
		var cited = new List<NoteCitationDraft>();
		foreach (var citation in citations ?? [])
		{
			if (!Days.TryParseTime(citation.At, conversation.StartedAt, zone, out var at))
			{
				return ToolResults.Error(ConversationTools.TimeHelp("citations[].at"));
			}

			DateTimeOffset? endAt = null;
			if (!string.IsNullOrWhiteSpace(citation.EndAt))
			{
				if (!Days.TryParseTime(citation.EndAt, conversation.StartedAt, zone, out var end))
				{
					return ToolResults.Error(ConversationTools.TimeHelp("citations[].end_at"));
				}

				endAt = end;
			}

			cited.Add(new NoteCitationDraft(conversationId, at, endAt));
		}

		var written = await requests.CreateNoteAsync(call.UserId, new NoteDraft(conversationId, ArchiveReader.Blank(title), body?.Trim(), cited), cancellationToken);
		var result = written.Outcome switch
		{
			PhoneWriteOutcome.Queued => new NoteWriteResult(
				$"Added a note to {Speak.Clause(ArchiveReader.Blank(conversation.Title) ?? "the conversation")}. {OnItsWay}",
				"added",
				archive.Note(call, written.Item!, conversation),
				written.RequestId),
			PhoneWriteOutcome.NotAllowed => new NoteWriteResult(NotAllowedSummary, "notAllowed", null, null),
			PhoneWriteOutcome.NotFound or PhoneWriteOutcome.Unchanged => new NoteWriteResult("I could not find that conversation in what you share, so nothing was added.", "notFound", null, null),
		};
		return await AnswerAsync(archive, call, "create_note", result, written.Item is { } note ? [note.Id, conversationId] : [], cancellationToken);
	}

	private static async Task<FollowUpOut> Shape(ArchiveReader archive, ToolCall call, FollowUp followUp, CancellationToken cancellationToken) =>
		(await archive.FollowUpsAsync(call, [followUp], cancellationToken))[0];

	private static async Task<CallToolResult> AnswerAsync<T>(ArchiveReader archive, ToolCall call, string tool, T result, IEnumerable<string> ids, CancellationToken cancellationToken)
		where T : IToolResult
	{
		await archive.LogAsync(call, tool, ids, cancellationToken);
		return ToolResults.Of(result);
	}

	/// <summary>Null when left out, a cleared value for <c>none</c>, else the time.</summary>
	private static bool TryOptionalTime(string? text, ToolCall call, out Settable<DateTimeOffset?>? value)
	{
		value = null;
		if (string.IsNullOrWhiteSpace(text))
		{
			return true;
		}

		if (text.Trim().Equals("none", StringComparison.OrdinalIgnoreCase))
		{
			value = new Settable<DateTimeOffset?>(null);
			return true;
		}

		if (IsNumber(text) || !Days.TryParseTime(text, call.Now, call.Zone, out var at))
		{
			return false;
		}

		value = new Settable<DateTimeOffset?>(at);
		return true;
	}

	private static bool IsNumber(string text) => double.TryParse(text.Trim(), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out _);
}
