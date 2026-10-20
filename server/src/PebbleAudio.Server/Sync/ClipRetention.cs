using Microsoft.EntityFrameworkCore;
using PebbleAudio.Server.Data;
using PebbleAudio.Server.Settings;

namespace PebbleAudio.Server.Sync;

/// <summary>
/// Removes clip audio the server no longer needs: a finished clip (ready, failed, or unavailable) once the
/// "How long clips are kept" setting has passed, and all of an account's clips when the phone turns clips off. A
/// clip goes with its request (cascade) and its file, so a later request asks the phone again.
/// </summary>
public sealed class ClipRetention(ArchiveDbContext db, ClipStorage storage, SettingsService settings, ILogger<ClipRetention> logger)
{
	/// <returns>How many clips were removed.</returns>
	public async Task<int> RemoveExpiredAsync(DateTimeOffset now, CancellationToken cancellationToken)
	{
		var cutoff = now - (await settings.GetAsync(cancellationToken)).ClipKeepTime;
		var removed = await RemoveAsync(
			db.Clips.Where(c =>
				(c.Status == ClipStatus.Ready || c.Status == ClipStatus.Failed || c.Status == ClipStatus.Unavailable) &&
				(c.ReadyAt ?? c.UploadedAt ?? c.CreatedAt) < cutoff),
			cancellationToken);
		if (removed > 0)
		{
			logger.LogInformation("Removed {Clips} clips kept since before {Cutoff:o}.", removed, cutoff);
		}

		return removed;
	}

	/// <summary>Every clip of the account, waiting or done: the person no longer lets assistants have audio.</summary>
	public Task<int> RemoveAllAsync(Guid userId, CancellationToken cancellationToken) =>
		RemoveAsync(db.Clips.Where(c => c.UserId == userId), cancellationToken);

	private async Task<int> RemoveAsync(IQueryable<Clip> clips, CancellationToken cancellationToken)
	{
		var found = await clips.Select(c => new { c.RequestId, c.Path }).ToListAsync(cancellationToken);
		if (found.Count == 0)
		{
			return 0;
		}

		var requestIds = found.Select(c => c.RequestId).ToList();
		await db.Requests.Where(r => requestIds.Contains(r.Id)).ExecuteDeleteAsync(cancellationToken);
		foreach (var path in found.Select(c => c.Path).OfType<string>())
		{
			storage.Delete(path);
		}

		return found.Count;
	}
}
