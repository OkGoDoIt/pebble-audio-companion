using System.Security.Claims;
using PebbleAudio.Server.Auth;
using PebbleAudio.Server.Data;

namespace PebbleAudio.Server.Mcp;

/// <summary>
/// Records each tool call by an assistant, so the phone can show what AI read.
/// </summary>
public sealed class AiReadLog(ArchiveDbContext db, TimeProvider time)
{
	public async Task RecordAsync(
		ClaimsPrincipal? caller,
		string tool,
		IReadOnlyCollection<string> entityIds,
		CancellationToken cancellationToken)
	{
		if (caller.UserId() is not { } userId)
		{
			return;
		}

		db.AiReads.Add(new AiRead
		{
			UserId = userId,
			At = time.GetUtcNow(),
			Client = caller.ClientName(),
			Tool = tool,
			EntityIds = [.. entityIds],
			ApiTokenId = caller.TokenId(),
		});
		await db.SaveChangesAsync(cancellationToken);
	}
}
