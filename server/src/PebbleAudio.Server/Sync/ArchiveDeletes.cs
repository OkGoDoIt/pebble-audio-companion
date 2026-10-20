using Microsoft.EntityFrameworkCore;
using PebbleAudio.Server.Data;

namespace PebbleAudio.Server.Sync;

/// <summary>
/// Deleting conversations and everything the server derived from them, shared by a phone's <c>delete</c> and the
/// sharing-scope deletion. It runs inside the caller's transaction; the clip files to remove once it commits are
/// added to <c>files</c>.
/// </summary>
internal static class ArchiveDeletes
{
	/// <summary>
	/// Conversations go with their transcripts, their notes, their clips and the requests for them, and their place
	/// in the AI-read log. Follow-ups said in them keep their text and lose the link back.
	/// </summary>
	public static async Task ConversationsAsync(
		ArchiveDbContext db,
		Guid userId,
		IReadOnlyList<string> ids,
		List<string> files,
		CancellationToken cancellationToken)
	{
		if (ids.Count == 0)
		{
			return;
		}

		await db.Conversations.Where(c => c.UserId == userId && ids.Contains(c.Id)).ExecuteDeleteAsync(cancellationToken);
		await db.Transcripts.Where(t => t.UserId == userId && ids.Contains(t.ConversationId)).ExecuteDeleteAsync(cancellationToken);
		await db.Notes.Where(n => n.UserId == userId && n.ConversationId != null && ids.Contains(n.ConversationId)).ExecuteDeleteAsync(cancellationToken);
		await db.FollowUps
			.Where(f => f.UserId == userId && f.SourceConversationId != null && ids.Contains(f.SourceConversationId))
			.ExecuteUpdateAsync(
				s => s
					.SetProperty(f => f.SourceConversationId, (string?)null)
					.SetProperty(f => f.SourceAt, (DateTimeOffset?)null)
					.SetProperty(f => f.SourceEndAt, (DateTimeOffset?)null)
					.SetProperty(f => f.SourceApproximate, false),
				cancellationToken);

		var clips = await db.Clips
			.Where(c => c.UserId == userId && ids.Contains(c.ConversationId))
			.Select(c => new { c.RequestId, c.Path })
			.ToListAsync(cancellationToken);
		if (clips.Count > 0)
		{
			var requestIds = clips.Select(c => c.RequestId).ToList();
			// Clips go with their requests (cascade).
			await db.Requests.Where(r => r.UserId == userId && requestIds.Contains(r.Id)).ExecuteDeleteAsync(cancellationToken);
			files.AddRange(clips.Select(c => c.Path).OfType<string>());
		}

		var removed = ids.ToArray();
		await db.Database.ExecuteSqlAsync(
			$"""
			UPDATE "AiReads" SET "EntityIds" = ARRAY(SELECT e FROM unnest("EntityIds") AS e WHERE e <> ALL({removed}))
			WHERE "UserId" = {userId} AND "EntityIds" && {removed}
			""",
			cancellationToken);
	}
}
