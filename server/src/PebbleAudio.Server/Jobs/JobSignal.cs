namespace PebbleAudio.Server.Jobs;

/// <summary>
/// Wakes the worker as soon as a job is enqueued in this process, instead of at its next poll.
/// </summary>
public sealed class JobSignal
{
	private readonly SemaphoreSlim _signal = new(0, 1);

	public void Wake()
	{
		try
		{
			_signal.Release();
		}
		catch (SemaphoreFullException)
		{
			// Already awake.
		}
	}

	public Task<bool> WaitAsync(TimeSpan timeout, CancellationToken cancellationToken) =>
		_signal.WaitAsync(timeout, cancellationToken);
}
