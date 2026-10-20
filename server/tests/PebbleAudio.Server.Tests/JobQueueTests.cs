using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using PebbleAudio.Server.Data;
using PebbleAudio.Server.Jobs;
using PebbleAudio.Server.Settings;

namespace PebbleAudio.Server.Tests;

[Collection(ServerCollection.Name)]
public sealed class JobQueueTests(ArchiveServerFactory factory)
{
	[Fact]
	public async Task Jobs_are_claimed_retried_with_backoff_and_set_aside_after_the_last_attempt()
	{
		var runner = factory.Services.GetRequiredService<JobRunner>();
		await using var scope = factory.Services.CreateAsyncScope();
		var db = scope.ServiceProvider.GetRequiredService<ArchiveDbContext>();
		var queue = scope.ServiceProvider.GetRequiredService<IJobQueue>();
		var settings = scope.ServiceProvider.GetRequiredService<SettingsService>();
		await db.Jobs.ExecuteDeleteAsync();

		// A job runs once and succeeds; then nothing is due.
		var noop = await queue.EnqueueAsync(NoopJobHandler.Type, new { reason = "test" });
		Assert.True(await runner.RunNextAsync(CancellationToken.None));
		var done = await Reload(db, noop);
		Assert.Equal(JobState.Succeeded, done.State);
		Assert.Equal(1, done.Attempts);
		Assert.NotNull(done.CompletedAt);
		Assert.False(await runner.RunNextAsync(CancellationToken.None));

		// A failure waits out its backoff, then the retry succeeds.
		var flaky = await queue.EnqueueAsync(FlakyJobHandler.Type);
		Assert.True(await runner.RunNextAsync(CancellationToken.None));
		var retrying = await Reload(db, flaky);
		Assert.Equal(JobState.Pending, retrying.State);
		Assert.Equal(1, retrying.Attempts);
		Assert.Contains("First attempts always fail.", retrying.Error);
		Assert.True(retrying.RunAfter > DateTimeOffset.UtcNow + JobRunner.RetryDelay(1) - TimeSpan.FromSeconds(10));
		Assert.False(await runner.RunNextAsync(CancellationToken.None));

		await MakeDue(db, flaky);
		Assert.True(await runner.RunNextAsync(CancellationToken.None));
		var recovered = await Reload(db, flaky);
		Assert.Equal(JobState.Succeeded, recovered.State);
		Assert.Equal(2, recovered.Attempts);

		// With two attempts allowed, a job that always fails is set aside after the second.
		await settings.SaveAsync(new Dictionary<string, int> { [nameof(ArchiveSettings.JobMaxAttempts)] = 2 }, CancellationToken.None);
		try
		{
			var failing = await queue.EnqueueAsync(FailingJobHandler.Type);
			Assert.True(await runner.RunNextAsync(CancellationToken.None));
			Assert.Equal(JobState.Pending, (await Reload(db, failing)).State);

			await MakeDue(db, failing);
			Assert.True(await runner.RunNextAsync(CancellationToken.None));
			var dead = await Reload(db, failing);
			Assert.Equal(JobState.DeadLettered, dead.State);
			Assert.Equal(2, dead.Attempts);
			Assert.Contains("This job never works.", dead.Error);
			Assert.False(await runner.RunNextAsync(CancellationToken.None));
		}
		finally
		{
			await settings.SaveAsync(new Dictionary<string, int> { [nameof(ArchiveSettings.JobMaxAttempts)] = ArchiveSettings.Defaults.JobMaxAttempts }, CancellationToken.None);
		}

		Assert.Equal(ArchiveSettings.Defaults.JobMaxAttempts, (await settings.GetAsync(CancellationToken.None)).JobMaxAttempts);
		Assert.False(await db.Settings.AnyAsync(), "A setting saved at its default is not stored.");

		// Only registered job types can be enqueued.
		await Assert.ThrowsAsync<ArgumentException>(() => queue.EnqueueAsync("no.such.job"));
	}

	[Fact]
	public async Task Jobs_left_running_by_a_stopped_process_go_back_to_the_queue()
	{
		var runner = factory.Services.GetRequiredService<JobRunner>();
		await using var scope = factory.Services.CreateAsyncScope();
		var db = scope.ServiceProvider.GetRequiredService<ArchiveDbContext>();
		await db.Jobs.ExecuteDeleteAsync();

		var orphan = new Job
		{
			Type = NoopJobHandler.Type,
			State = JobState.Running,
			Attempts = 1,
			LockedBy = "old-host:1234",
			LockedAt = DateTimeOffset.UtcNow.AddMinutes(-3),
			RunAfter = DateTimeOffset.UtcNow.AddMinutes(-3),
			CreatedAt = DateTimeOffset.UtcNow.AddMinutes(-3),
		};
		db.Jobs.Add(orphan);
		await db.SaveChangesAsync();

		Assert.Equal(1, await runner.ReleaseOrphansAsync(CancellationToken.None));
		Assert.True(await runner.RunNextAsync(CancellationToken.None));
		var finished = await Reload(db, orphan.Id);
		Assert.Equal(JobState.Succeeded, finished.State);
		Assert.Equal(2, finished.Attempts);
	}

	private static Task<Job> Reload(ArchiveDbContext db, long id) =>
		db.Jobs.AsNoTracking().SingleAsync(j => j.Id == id);

	private static Task MakeDue(ArchiveDbContext db, long id) =>
		db.Jobs.Where(j => j.Id == id).ExecuteUpdateAsync(s => s.SetProperty(j => j.RunAfter, DateTimeOffset.UtcNow.AddSeconds(-1)));
}
