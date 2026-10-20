using Microsoft.EntityFrameworkCore;
using PebbleAudio.Server.Data;

namespace PebbleAudio.Server.Sync;

/// <summary>
/// <c>POST /sync/wipe</c> (sync-protocol.md §5): the app's Delete all. Every archive row and clip file of the
/// user goes, with the sync ledger, the requests, their jobs, and the AI-read log. What stays is what lets the
/// phone keep syncing and the person keep their setup: the linked phones, their preferences, the assistants'
/// tokens, and the admin account.
/// </summary>
public sealed class ArchiveWipe(ArchiveDbContext db, ClipStorage storage)
{
	public async Task WipeAsync(Guid userId, CancellationToken cancellationToken)
	{
		await using (var transaction = await db.Database.BeginTransactionAsync(cancellationToken))
		{
			await SyncLocks.LockUserAsync(db, userId, cancellationToken);
			await db.Requests.Where(r => r.UserId == userId).ExecuteDeleteAsync(cancellationToken);
			await db.Clips.Where(c => c.UserId == userId).ExecuteDeleteAsync(cancellationToken);
			await db.Jobs.Where(j => j.UserId == userId).ExecuteDeleteAsync(cancellationToken);
			await db.Conversations.Where(c => c.UserId == userId).ExecuteDeleteAsync(cancellationToken);
			await db.Transcripts.Where(t => t.UserId == userId).ExecuteDeleteAsync(cancellationToken);
			await db.Recaps.Where(r => r.UserId == userId).ExecuteDeleteAsync(cancellationToken);
			await db.Briefs.Where(b => b.UserId == userId).ExecuteDeleteAsync(cancellationToken);
			await db.FollowUps.Where(f => f.UserId == userId).ExecuteDeleteAsync(cancellationToken);
			await db.Notes.Where(n => n.UserId == userId).ExecuteDeleteAsync(cancellationToken);
			await db.People.Where(p => p.UserId == userId).ExecuteDeleteAsync(cancellationToken);
			await db.CoverageDays.Where(c => c.UserId == userId).ExecuteDeleteAsync(cancellationToken);
			await db.SyncItems.Where(s => s.UserId == userId).ExecuteDeleteAsync(cancellationToken);
			await db.AiReads.Where(a => a.UserId == userId).ExecuteDeleteAsync(cancellationToken);
			await transaction.CommitAsync(cancellationToken);
		}

		storage.DeleteUser(userId);
	}
}
