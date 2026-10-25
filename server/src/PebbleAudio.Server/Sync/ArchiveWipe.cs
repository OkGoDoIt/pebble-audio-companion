using Microsoft.EntityFrameworkCore;
using PebbleAudio.Server.Data;

namespace PebbleAudio.Server.Sync;

/// <summary>
/// Deleting a user's whole archive. <see cref="WipeAsync"/> is <c>POST /sync/wipe</c> (sync-protocol.md §5), the
/// app's Delete all: every archive row and clip file goes, with the sync ledger, the requests, their jobs, and the
/// AI-read log, and what lets the phone keep syncing stays (the linked phones, their preferences, the assistants'
/// access). <see cref="UnlinkAsync"/> is <c>DELETE /link</c> (§1): the same deletion, and every assistant's access
/// and this phone's token end with it. <see cref="UnlinkFromAdminAsync"/> is the admin area's Unlink.
/// </summary>
public sealed class ArchiveWipe(ArchiveDbContext db, ClipStorage storage, IConnectedAssistants assistants, TimeProvider time)
{
	public async Task WipeAsync(Guid userId, CancellationToken cancellationToken)
	{
		await using (var transaction = await db.Database.BeginTransactionAsync(cancellationToken))
		{
			await SyncLocks.LockUserAsync(db, userId, cancellationToken);
			await DeleteArchiveAsync(userId, cancellationToken);
			await transaction.CommitAsync(cancellationToken);
		}

		storage.DeleteUser(userId);
	}

	/// <summary>
	/// Unlinks the phone and leaves nothing behind: the archive goes as in <see cref="WipeAsync"/>, every OAuth
	/// connection and personal token is revoked, every event subscription ends, and the phone's token stops working,
	/// all in one transaction. The account itself, its other phones, and its preferences stay.
	/// </summary>
	public async Task UnlinkAsync(Guid userId, Guid deviceId, CancellationToken cancellationToken)
	{
		await using (var transaction = await db.Database.BeginTransactionAsync(cancellationToken))
		{
			await SyncLocks.LockUserAsync(db, userId, cancellationToken);
			await DeleteEverythingAsync(userId, deviceId, cancellationToken);
			await transaction.CommitAsync(cancellationToken);
		}

		storage.DeleteUser(userId);
	}

	/// <summary>
	/// The admin area's Unlink. The last linked phone goes as <see cref="UnlinkAsync"/> does: unlinking must clear the
	/// server (sync-protocol.md §1). While another phone stays linked, only this one's token ends, and the archive
	/// stays for the phone that keeps syncing it.
	/// </summary>
	/// <returns>False when the phone is not linked.</returns>
	public async Task<bool> UnlinkFromAdminAsync(Guid userId, Guid deviceId, CancellationToken cancellationToken)
	{
		bool last;
		await using (var transaction = await db.Database.BeginTransactionAsync(cancellationToken))
		{
			await SyncLocks.LockUserAsync(db, userId, cancellationToken);
			var linked = await db.Devices
				.Where(d => d.UserId == userId && d.UnlinkedAt == null)
				.Select(d => d.Id)
				.ToListAsync(cancellationToken);
			if (!linked.Contains(deviceId))
			{
				return false;
			}

			last = linked.Count == 1;
			if (last)
			{
				await DeleteEverythingAsync(userId, deviceId, cancellationToken);
			}
			else
			{
				await RevokeDeviceAsync(userId, deviceId, cancellationToken);
			}

			await transaction.CommitAsync(cancellationToken);
		}

		if (last)
		{
			storage.DeleteUser(userId);
		}

		return true;
	}

	private async Task DeleteEverythingAsync(Guid userId, Guid deviceId, CancellationToken cancellationToken)
	{
		await DeleteArchiveAsync(userId, cancellationToken);
		await assistants.RevokeAllAsync(userId, cancellationToken);
		await db.EventSubscriptions.Where(s => s.UserId == userId).ExecuteDeleteAsync(cancellationToken);
		await RevokeDeviceAsync(userId, deviceId, cancellationToken);
	}

	private async Task RevokeDeviceAsync(Guid userId, Guid deviceId, CancellationToken cancellationToken)
	{
		var now = time.GetUtcNow();
		await db.Devices
			.Where(d => d.Id == deviceId && d.UserId == userId && d.UnlinkedAt == null)
			.ExecuteUpdateAsync(s => s.SetProperty(d => d.UnlinkedAt, now), cancellationToken);
	}

	private async Task DeleteArchiveAsync(Guid userId, CancellationToken cancellationToken)
	{
		// Noted with the preferences, which stay: a backup import reads it so it does not bring the archive back.
		var now = time.GetUtcNow();
		if (await db.SyncPreferences.Where(p => p.UserId == userId).ExecuteUpdateAsync(s => s.SetProperty(p => p.WipedAt, now), cancellationToken) == 0)
		{
			db.SyncPreferences.Add(new SyncPreferences { UserId = userId, WipedAt = now, UpdatedAt = now });
			await db.SaveChangesAsync(cancellationToken);
		}

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
		await db.VoiceRevocations.Where(r => r.UserId == userId).ExecuteDeleteAsync(cancellationToken);
		await db.CoverageDays.Where(c => c.UserId == userId).ExecuteDeleteAsync(cancellationToken);
		await db.SyncItems.Where(s => s.UserId == userId).ExecuteDeleteAsync(cancellationToken);
		await db.AiReads.Where(a => a.UserId == userId).ExecuteDeleteAsync(cancellationToken);
	}
}
