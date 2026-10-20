using System.ComponentModel;
using ModelContextProtocol;
using ModelContextProtocol.Protocol;
using ModelContextProtocol.Server;
using PebbleAudio.Server.Auth;
using PebbleAudio.Server.Data;

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
		UseStructuredContent = true)]
	[Description(
		"Shows what the archive holds: how many conversations, transcripts, day recaps, briefs, follow-ups, " +
		"notes, people, and coverage days it has, the first and last day on record, when the phone last " +
		"synced, how many requests are waiting for the phone, and the server's current time. Call it first " +
		"to see how fresh the archive is.")]
	public static async Task<ArchiveStatus> GetStatus(
		RequestContext<CallToolRequestParams> context,
		ArchiveStatusService status,
		AiReadLog reads,
		CancellationToken cancellationToken)
	{
		var userId = context.User.UserId()
			?? throw new McpException("This request is not signed in to an archive.");

		var result = await status.GetAsync(userId, cancellationToken);
		await reads.RecordAsync(context.User, "get_status", [], cancellationToken);
		return result;
	}
}
