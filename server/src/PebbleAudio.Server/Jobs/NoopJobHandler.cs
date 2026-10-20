namespace PebbleAudio.Server.Jobs;

/// <summary>
/// Does nothing. Proves the queue end to end.
/// </summary>
public sealed class NoopJobHandler : IJobHandler
{
	public const string Type = "noop";

	public Task RunAsync(JobContext job, CancellationToken cancellationToken) => Task.CompletedTask;
}
