namespace PebbleAudio.Server.Jobs;

/// <summary>
/// Runs queued jobs one at a time: right away when one is enqueued in this process, otherwise on a short poll.
/// </summary>
public sealed class JobWorker(JobRunner runner, JobSignal signal, ILogger<JobWorker> logger) : BackgroundService
{
	private static readonly TimeSpan PollInterval = TimeSpan.FromSeconds(5);
	private static readonly TimeSpan ErrorPause = TimeSpan.FromSeconds(30);

	protected override async Task ExecuteAsync(CancellationToken stoppingToken)
	{
		try
		{
			await runner.ReleaseOrphansAsync(stoppingToken);
		}
		catch (Exception ex) when (ex is not OperationCanceledException)
		{
			logger.LogError(ex, "Could not return interrupted jobs to the queue.");
		}

		while (!stoppingToken.IsCancellationRequested)
		{
			try
			{
				if (await runner.RunNextAsync(stoppingToken))
				{
					continue;
				}

				await signal.WaitAsync(PollInterval, stoppingToken);
			}
			catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
			{
				break;
			}
			catch (Exception ex)
			{
				logger.LogError(ex, "The job queue could not be read; trying again in {Pause}.", ErrorPause);
				try
				{
					await Task.Delay(ErrorPause, stoppingToken);
				}
				catch (OperationCanceledException)
				{
					break;
				}
			}
		}
	}
}
