using Microsoft.EntityFrameworkCore;
using PebbleAudio.Server.Data;
using PebbleAudio.Server.Jobs;

namespace PebbleAudio.Server.Sync;

/// <summary>
/// Deletes everything that has fallen outside the account's sharing scope (sync-protocol.md §5): conversations with
/// their transcripts, notes, and clip files; transcripts without a conversation whose first item is earlier; recaps
/// and coverage for earlier days; briefs whose period ended earlier; follow-ups said (or, without a source, created)
/// earlier; notes without a conversation created earlier.
/// It runs nightly at 03:30 in the account's time zone and at once when the phone changes the scope.
/// </summary>
/// <remarks>
/// The sync ledger's rows for what it removes go too, so when the person widens the scope and the phone sends those
/// items again at their old versions, they are taken as new rather than as replays.
/// </remarks>
public sealed class ScopeSweep(ArchiveDbContext db, ClipStorage storage, SharingScopes scopes, ILogger<ScopeSweep> logger)
{
	public async Task<ScopeSweepResult> RunAsync(Guid userId, CancellationToken cancellationToken)
	{
		var scope = await scopes.GetAsync(userId, cancellationToken);
		if (scope is not { From: { } from, FromDay: { } fromDay })
		{
			return ScopeSweepResult.Nothing;
		}

		var files = new List<string>();
		ScopeSweepResult result;
		await using (var transaction = await db.Database.BeginTransactionAsync(cancellationToken))
		{
			await SyncLocks.LockUserAsync(db, userId, cancellationToken);

			// Follow-ups first: deleting a conversation clears the source time of the follow-ups said in it, and they
			// are dated by that time.
			var followUps = db.FollowUps.Where(f => f.UserId == userId && (f.SourceAt ?? f.CreatedAt) < from);
			var followUpIds = await followUps.Select(f => f.Id).ToListAsync(cancellationToken);
			await followUps.ExecuteDeleteAsync(cancellationToken);

			var conversations = await db.Conversations
				.Where(c => c.UserId == userId && c.StartedAt < from)
				.Select(c => c.Id)
				.ToListAsync(cancellationToken);
			await ArchiveDeletes.ConversationsAsync(db, userId, conversations, files, cancellationToken);

			// A transcript whose conversation is not here is dated by its first item, as a batch dates it.
			var orphans = (await db.Transcripts
					.Where(t => t.UserId == userId && !db.Conversations.Any(c => c.UserId == userId && c.Id == t.ConversationId))
					.Select(t => new { t.ConversationId, First = t.Items.Min(i => (DateTimeOffset?)i.At) })
					.ToListAsync(cancellationToken))
				.Where(t => t.First < from)
				.Select(t => t.ConversationId)
				.ToList();
			if (orphans.Count > 0)
			{
				await db.Transcripts.Where(t => t.UserId == userId && orphans.Contains(t.ConversationId)).ExecuteDeleteAsync(cancellationToken);
			}

			var recaps = await db.Recaps.Where(r => r.UserId == userId && r.DayKey < fromDay).Select(r => r.DayKey).ToListAsync(cancellationToken);
			await db.Recaps.Where(r => r.UserId == userId && r.DayKey < fromDay).ExecuteDeleteAsync(cancellationToken);

			var coverage = await db.CoverageDays.Where(c => c.UserId == userId && c.DayKey < fromDay).Select(c => c.DayKey).ToListAsync(cancellationToken);
			await db.CoverageDays.Where(c => c.UserId == userId && c.DayKey < fromDay).ExecuteDeleteAsync(cancellationToken);

			var briefs = await db.Briefs.Where(b => b.UserId == userId && b.EndDay < fromDay).Select(b => b.PeriodKey).ToListAsync(cancellationToken);
			await db.Briefs.Where(b => b.UserId == userId && b.EndDay < fromDay).ExecuteDeleteAsync(cancellationToken);

			// Notes on a conversation went with it above; one with none here is dated by when it was written.
			var notes = db.Notes.Where(n =>
				n.UserId == userId &&
				n.CreatedAt < from &&
				!db.Conversations.Any(c => c.UserId == userId && c.Id == n.ConversationId));
			var noteIds = await notes.Select(n => n.Id).ToListAsync(cancellationToken);
			await notes.ExecuteDeleteAsync(cancellationToken);

			await ForgetAsync(userId, SyncKind.Conversation, conversations, cancellationToken);
			await ForgetAsync(userId, SyncKind.Transcript, [.. conversations, .. orphans], cancellationToken);
			await ForgetAsync(userId, SyncKind.Recap, [.. recaps.Select(Day)], cancellationToken);
			await ForgetAsync(userId, SyncKind.Coverage, [.. coverage.Select(Day)], cancellationToken);
			await ForgetAsync(userId, SyncKind.Brief, briefs, cancellationToken);
			await ForgetAsync(userId, SyncKind.FollowUp, followUpIds, cancellationToken);
			await ForgetAsync(userId, SyncKind.Note, noteIds, cancellationToken);

			await transaction.CommitAsync(cancellationToken);
			result = new ScopeSweepResult(conversations.Count, recaps.Count, briefs.Count, followUpIds.Count, noteIds.Count, coverage.Count, files.Count);
		}

		foreach (var file in files)
		{
			storage.Delete(file);
		}

		if (result != ScopeSweepResult.Nothing)
		{
			logger.LogInformation(
				"Sharing scope: removed {Conversations} conversations, {Recaps} recaps, {Briefs} briefs, {FollowUps} follow-ups, {Notes} notes, {Coverage} coverage days, and {Clips} clip files dated before {From:o}.",
				result.Conversations,
				result.Recaps,
				result.Briefs,
				result.FollowUps,
				result.Notes,
				result.CoverageDays,
				result.ClipFiles,
				from);
		}

		return result;
	}

	private async Task ForgetAsync(Guid userId, SyncKind kind, IReadOnlyList<string> ids, CancellationToken cancellationToken)
	{
		if (ids.Count > 0)
		{
			await db.SyncItems.Where(s => s.UserId == userId && s.Kind == kind && ids.Contains(s.EntityId)).ExecuteDeleteAsync(cancellationToken);
		}
	}

	private static string Day(DateOnly day) => day.ToString("yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture);
}

/// <summary>How much one sharing-scope deletion removed.</summary>
public sealed record ScopeSweepResult(int Conversations, int Recaps, int Briefs, int FollowUps, int Notes, int CoverageDays, int ClipFiles)
{
	public static ScopeSweepResult Nothing { get; } = new(0, 0, 0, 0, 0, 0, 0);
}

/// <summary>The nightly sharing-scope deletion for one account, queued by <see cref="ScopeSweepScheduler"/>.</summary>
public sealed class ScopeSweepJob(ScopeSweep sweep) : IJobHandler
{
	public const string Type = "scope.sweep";

	public async Task RunAsync(JobContext job, CancellationToken cancellationToken)
	{
		if (job.UserId is { } userId)
		{
			await sweep.RunAsync(userId, cancellationToken);
		}
	}
}

/// <summary>
/// Queues each account's sharing-scope deletion once a night, at 03:30 in its time zone. Accounts that share
/// everything are skipped.
/// </summary>
public sealed class ScopeSweepSchedule(ArchiveDbContext db, IJobQueue queue)
{
	/// <returns>How many deletions were queued.</returns>
	public async Task<int> QueueDueAsync(DateTimeOffset now, CancellationToken cancellationToken)
	{
		var rows = await db.SyncPreferences.Where(p => p.ScopeKind != SharingScopeKind.All).ToListAsync(cancellationToken);
		var queued = 0;
		foreach (var row in rows)
		{
			var slot = SharingScopes.LatestSweepSlot(now, LogicalDays.Zone(row.TimeZone));
			if (row.ScopeSweptFor is { } swept && swept >= slot)
			{
				continue;
			}

			row.ScopeSweptFor = slot;
			// Saves the mark and the job together, so a night is queued once.
			await queue.EnqueueAsync(ScopeSweepJob.Type, userId: row.UserId, cancellationToken: cancellationToken);
			queued++;
		}

		return queued;
	}
}

/// <summary>
/// Looks for due nightly deletions every ten minutes, and removes clips past the "How long clips are kept" setting.
/// </summary>
public sealed class ScopeSweepScheduler(IServiceScopeFactory scopes, TimeProvider time, ILogger<ScopeSweepScheduler> logger) : BackgroundService
{
	public static readonly TimeSpan Interval = TimeSpan.FromMinutes(10);

	protected override async Task ExecuteAsync(CancellationToken stoppingToken)
	{
		using var timer = new PeriodicTimer(Interval, time);
		do
		{
			try
			{
				await using var scope = scopes.CreateAsyncScope();
				await scope.ServiceProvider.GetRequiredService<ScopeSweepSchedule>().QueueDueAsync(time.GetUtcNow(), stoppingToken);
				await scope.ServiceProvider.GetRequiredService<ClipRetention>().RemoveExpiredAsync(time.GetUtcNow(), stoppingToken);
			}
			catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
			{
				break;
			}
			catch (Exception ex)
			{
				logger.LogError(ex, "Could not queue the nightly sharing-scope deletions or remove old clips.");
			}
		}
		while (await WaitAsync(timer, stoppingToken));
	}

	private static async Task<bool> WaitAsync(PeriodicTimer timer, CancellationToken stoppingToken)
	{
		try
		{
			return await timer.WaitForNextTickAsync(stoppingToken);
		}
		catch (OperationCanceledException)
		{
			return false;
		}
	}
}
