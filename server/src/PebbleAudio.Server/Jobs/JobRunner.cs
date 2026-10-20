using Microsoft.EntityFrameworkCore;
using PebbleAudio.Server.Data;
using PebbleAudio.Server.Settings;

namespace PebbleAudio.Server.Jobs;

/// <summary>
/// Claims and runs one job at a time. Claiming is a single <c>UPDATE … WHERE "Id" = (SELECT … FOR UPDATE
/// SKIP LOCKED) RETURNING *</c>, so no transaction stays open while a handler runs.
/// </summary>
public sealed class JobRunner(IServiceScopeFactory scopes, TimeProvider time, ILogger<JobRunner> logger)
{
	private static readonly TimeSpan FirstRetryDelay = TimeSpan.FromSeconds(30);
	private static readonly TimeSpan LongestRetryDelay = TimeSpan.FromHours(1);
	private const int ErrorLength = 4000;

	public string WorkerId { get; } = $"{Environment.MachineName}:{Environment.ProcessId}";

	/// <summary>
	/// The wait before the next attempt: 30 s after the first failure, doubling, at most an hour.
	/// </summary>
	public static TimeSpan RetryDelay(int attempts)
	{
		var exponent = Math.Clamp(attempts - 1, 0, 20);
		var delay = FirstRetryDelay * Math.Pow(2, exponent);
		return delay < LongestRetryDelay ? delay : LongestRetryDelay;
	}

	/// <summary>
	/// Runs the next due job, if there is one.
	/// </summary>
	/// <returns>True when a job was claimed (whatever its outcome), false when none was due.</returns>
	public async Task<bool> RunNextAsync(CancellationToken cancellationToken)
	{
		await using var scope = scopes.CreateAsyncScope();
		var db = scope.ServiceProvider.GetRequiredService<ArchiveDbContext>();
		var now = time.GetUtcNow();

		var claimed = await db.Jobs
			.FromSql($"""
				UPDATE "Jobs"
				SET "State" = 'Running', "Attempts" = "Attempts" + 1, "LockedBy" = {WorkerId}, "LockedAt" = {now}
				WHERE "Id" = (
					SELECT "Id" FROM "Jobs"
					WHERE "State" = 'Pending' AND "RunAfter" <= {now}
					ORDER BY "RunAfter", "Id"
					LIMIT 1
					FOR UPDATE SKIP LOCKED)
				RETURNING *
				""")
			.AsNoTracking()
			.ToListAsync(cancellationToken);

		if (claimed is not [var job])
		{
			return false;
		}

		try
		{
			var handler = scope.ServiceProvider.GetKeyedService<IJobHandler>(job.Type)
				?? throw new InvalidOperationException($"No job handler is registered for '{job.Type}'.");
			var context = new JobContext(job.Id, job.Type, job.Payload?.RootElement.Clone(), job.Attempts, job.UserId);
			await handler.RunAsync(context, cancellationToken);

			await db.Jobs
				.Where(j => j.Id == job.Id)
				.ExecuteUpdateAsync(
					s => s
						.SetProperty(j => j.State, JobState.Succeeded)
						.SetProperty(j => j.CompletedAt, time.GetUtcNow())
						.SetProperty(j => j.LockedBy, (string?)null)
						.SetProperty(j => j.LockedAt, (DateTimeOffset?)null),
					CancellationToken.None);
			logger.LogInformation(
				"Job {JobId} ({JobType}) succeeded on attempt {Attempt}.",
				job.Id,
				job.Type,
				job.Attempts);
		}
		catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
		{
			// Shutting down: hand the job back untouched; this attempt does not count.
			await db.Jobs
				.Where(j => j.Id == job.Id)
				.ExecuteUpdateAsync(
					s => s
						.SetProperty(j => j.State, JobState.Pending)
						.SetProperty(j => j.Attempts, j => j.Attempts - 1)
						.SetProperty(j => j.LockedBy, (string?)null)
						.SetProperty(j => j.LockedAt, (DateTimeOffset?)null),
					CancellationToken.None);
			throw;
		}
		catch (Exception ex)
		{
			await RecordFailureAsync(scope.ServiceProvider, db, job, ex);
		}

		return true;
	}

	/// <summary>
	/// Returns jobs a previous process left running to the queue. Only one instance of the app runs, so at
	/// startup any running job is an orphan of a process that stopped mid-job.
	/// </summary>
	public async Task<int> ReleaseOrphansAsync(CancellationToken cancellationToken)
	{
		await using var scope = scopes.CreateAsyncScope();
		var db = scope.ServiceProvider.GetRequiredService<ArchiveDbContext>();
		var released = await db.Jobs
			.Where(j => j.State == JobState.Running)
			.ExecuteUpdateAsync(
				s => s
					.SetProperty(j => j.State, JobState.Pending)
					.SetProperty(j => j.LockedBy, (string?)null)
					.SetProperty(j => j.LockedAt, (DateTimeOffset?)null),
				cancellationToken);
		if (released > 0)
		{
			logger.LogWarning("Returned {Count} interrupted job(s) to the queue.", released);
		}

		return released;
	}

	private async Task RecordFailureAsync(IServiceProvider services, ArchiveDbContext db, Job job, Exception ex)
	{
		var settings = await services.GetRequiredService<SettingsService>().GetAsync(CancellationToken.None);
		var error = ex.ToString();
		if (error.Length > ErrorLength)
		{
			error = error[..ErrorLength];
		}

		var now = time.GetUtcNow();
		if (job.Attempts >= settings.JobMaxAttempts)
		{
			await db.Jobs
				.Where(j => j.Id == job.Id)
				.ExecuteUpdateAsync(
					s => s
						.SetProperty(j => j.State, JobState.DeadLettered)
						.SetProperty(j => j.Error, error)
						.SetProperty(j => j.CompletedAt, now)
						.SetProperty(j => j.LockedBy, (string?)null)
						.SetProperty(j => j.LockedAt, (DateTimeOffset?)null),
					CancellationToken.None);
			logger.LogError(
				ex,
				"Job {JobId} ({JobType}) failed on attempt {Attempt} of {MaxAttempts} and was set aside.",
				job.Id,
				job.Type,
				job.Attempts,
				settings.JobMaxAttempts);
			return;
		}

		var runAfter = now + RetryDelay(job.Attempts);
		await db.Jobs
			.Where(j => j.Id == job.Id)
			.ExecuteUpdateAsync(
				s => s
					.SetProperty(j => j.State, JobState.Pending)
					.SetProperty(j => j.Error, error)
					.SetProperty(j => j.RunAfter, runAfter)
					.SetProperty(j => j.LockedBy, (string?)null)
					.SetProperty(j => j.LockedAt, (DateTimeOffset?)null),
				CancellationToken.None);
		logger.LogWarning(
			ex,
			"Job {JobId} ({JobType}) failed on attempt {Attempt} of {MaxAttempts}; retrying after {RunAfter}.",
			job.Id,
			job.Type,
			job.Attempts,
			settings.JobMaxAttempts,
			runAfter);
	}
}
