using System.ComponentModel;
using Microsoft.EntityFrameworkCore;
using ModelContextProtocol.Protocol;
using ModelContextProtocol.Server;
using PebbleAudio.Server.Auth;
using PebbleAudio.Server.Data;
using PebbleAudio.Server.Sync;

namespace PebbleAudio.Server.Mcp;

[McpServerToolType]
public sealed class StatusTools
{
	[McpServerTool(
		Name = "get_status",
		Title = "Archive status",
		ReadOnly = true,
		Destructive = false,
		Idempotent = true,
		OpenWorld = false,
		UseStructuredContent = true,
		OutputSchemaType = typeof(StatusResult))]
	[McpMeta("openai/toolInvocation/invoking", "Checking your archive…")]
	[McpMeta("openai/toolInvocation/invoked", "Checked your archive")]
	[Description(
		"What the archive holds and how fresh it is: counts of conversations, transcripts, day recaps, briefs, " +
		"follow-ups, notes, and people; the first and last day on record; when the phone last synced; what the " +
		"person shares (all, since a date, or the last N days) and allows (audio clips, adding follow-ups and notes). " +
		"Call it when freshness matters or before saying something is not in the archive.")]
	public static async Task<CallToolResult> GetStatus(
		RequestContext<CallToolRequestParams> context,
		ArchiveReader archive,
		PhoneRequestService requests,
		CancellationToken cancellationToken)
	{
		var call = await archive.BeginAsync(context.User, cancellationToken);
		var db = archive.Db;
		var userId = call.UserId;
		var conversations = archive.Conversations(call);
		var counts = new CountsOut(
			await conversations.CountAsync(cancellationToken),
			await archive.Transcripts(call).CountAsync(cancellationToken),
			await archive.Recaps(call).CountAsync(cancellationToken),
			await archive.Briefs(call).CountAsync(cancellationToken),
			await archive.FollowUps(call).CountAsync(cancellationToken),
			await archive.Notes(call).CountAsync(cancellationToken),
			await archive.People(call).CountAsync(cancellationToken),
			await archive.Coverage(call).CountAsync(cancellationToken));
		var firstDay = await conversations.MinAsync(c => (DateOnly?)c.DayKey, cancellationToken);
		var lastDay = await conversations.MaxAsync(c => (DateOnly?)c.DayKey, cancellationToken);
		var lastSyncAt = await db.Devices.Where(d => d.UserId == userId).MaxAsync(d => d.LastBatchAt, cancellationToken);
		var pending = await db.Requests.CountAsync(r => r.UserId == userId && r.State == PhoneRequestState.Pending, cancellationToken);
		var phones = await db.Devices.CountAsync(d => d.UserId == userId && d.UnlinkedAt == null, cancellationToken);
		var preferences = await requests.GetPreferencesAsync(userId, cancellationToken);
		var scope = call.Scope;

		var summary = counts.Conversations == 0
			? "Your archive has no conversations yet."
			: $"Your archive holds {Speak.Count(counts.Conversations, "conversation", "conversations")} from " +
				$"{Speak.ShortDay(firstDay!.Value, call.Today)} to {Speak.ShortDay(lastDay!.Value, call.Today)}";
		if (counts.Conversations > 0)
		{
			summary += lastSyncAt is { } synced ? $"; your phone last synced {Speak.Ago(call.Now - synced)}." : ".";
		}

		summary += scope.Kind switch
		{
			SharingScopeKind.All => "",
			SharingScopeKind.Since => $" You share conversations from {Speak.ShortDay(LogicalDays.Of(scope.Since!.Value, call.Zone), call.Today)} on.",
			SharingScopeKind.LastDays => $" You share the last {Speak.Count(scope.Days!.Value, "day", "days")}.",
		};

		var result = new StatusResult(
			summary,
			lastDay is { } last ? archive.Links.Day(last) : null,
			Days.Local(call.Now, call.Zone),
			scope.TimeZoneId,
			firstDay,
			lastDay,
			Days.Local(lastSyncAt, call.Zone),
			counts,
			pending,
			phones,
			AppVersion.Display,
			new SharingOut(scope.Kind.ToWire(), Days.Local(scope.Since, call.Zone), scope.Days, Days.Local(scope.From, call.Zone)),
			new AllowedOut(preferences.Clips, preferences.Edits),
			context.User.HasScope(ArchiveScopes.Write));
		await archive.LogAsync(call, "get_status", [], cancellationToken);
		return ToolResults.Of(result);
	}
}
