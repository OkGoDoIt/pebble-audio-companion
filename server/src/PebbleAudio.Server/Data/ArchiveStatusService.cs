using Microsoft.EntityFrameworkCore;

namespace PebbleAudio.Server.Data;

/// <summary>
/// What the archive holds for one user, for the admin status page and the <c>get_status</c> tool.
/// </summary>
public sealed class ArchiveStatusService(ArchiveDbContext db, TimeProvider time)
{
	public async Task<ArchiveStatus> GetAsync(Guid userId, CancellationToken cancellationToken)
	{
		var counts = new ArchiveCounts(
			Conversations: await db.Conversations.CountAsync(c => c.UserId == userId, cancellationToken),
			Transcripts: await db.Transcripts.CountAsync(t => t.UserId == userId, cancellationToken),
			Recaps: await db.Recaps.CountAsync(r => r.UserId == userId, cancellationToken),
			Briefs: await db.Briefs.CountAsync(b => b.UserId == userId, cancellationToken),
			FollowUps: await db.FollowUps.CountAsync(f => f.UserId == userId, cancellationToken),
			Notes: await db.Notes.CountAsync(n => n.UserId == userId, cancellationToken),
			People: await db.People.CountAsync(p => p.UserId == userId, cancellationToken),
			CoverageDays: await db.CoverageDays.CountAsync(c => c.UserId == userId, cancellationToken));

		var conversations = db.Conversations.Where(c => c.UserId == userId);
		var firstDay = await conversations.MinAsync(c => (DateOnly?)c.DayKey, cancellationToken);
		var lastDay = await conversations.MaxAsync(c => (DateOnly?)c.DayKey, cancellationToken);
		var lastSyncAt = await db.SyncItems
			.Where(s => s.UserId == userId)
			.MaxAsync(s => (DateTimeOffset?)s.AppliedAt, cancellationToken);
		var pendingRequests = await db.Requests
			.CountAsync(r => r.UserId == userId && r.State == PhoneRequestState.Pending, cancellationToken);
		var linkedPhones = await db.Devices
			.CountAsync(d => d.UserId == userId && d.UnlinkedAt == null, cancellationToken);

		return new ArchiveStatus(
			ServerTime: time.GetUtcNow(),
			Counts: counts,
			FirstDay: firstDay,
			LastDay: lastDay,
			LastSyncAt: lastSyncAt,
			PendingRequests: pendingRequests,
			LinkedPhones: linkedPhones,
			ServerVersion: AppVersion.Display);
	}
}

/// <summary>
/// What the archive holds and how fresh it is.
/// </summary>
/// <param name="ServerTime">The server's clock, UTC.</param>
/// <param name="Counts">Rows per kind of entity.</param>
/// <param name="FirstDay">The earliest logical day with a conversation.</param>
/// <param name="LastDay">The latest logical day with a conversation.</param>
/// <param name="LastSyncAt">When the phone's last change was applied; null if it never synced.</param>
/// <param name="PendingRequests">Requests waiting for the phone.</param>
/// <param name="LinkedPhones">Phones that can sync.</param>
/// <param name="ServerVersion">The running build.</param>
public sealed record ArchiveStatus(
	DateTimeOffset ServerTime,
	ArchiveCounts Counts,
	DateOnly? FirstDay,
	DateOnly? LastDay,
	DateTimeOffset? LastSyncAt,
	int PendingRequests,
	int LinkedPhones,
	string ServerVersion);

/// <summary>
/// Rows per kind of entity.
/// </summary>
public sealed record ArchiveCounts(
	int Conversations,
	int Transcripts,
	int Recaps,
	int Briefs,
	int FollowUps,
	int Notes,
	int People,
	int CoverageDays);
