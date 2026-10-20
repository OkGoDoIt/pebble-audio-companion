namespace PebbleAudio.Server.Jobs;

/// <summary>
/// Puts work on the Postgres-backed task queue.
/// </summary>
public interface IJobQueue
{
	/// <summary>
	/// Adds a job and saves the database context, so it commits together with any changes the caller has
	/// pending on the same context (and inside the caller's transaction, if one is open).
	/// </summary>
	/// <param name="type">A registered handler's name, for example <see cref="NoopJobHandler.Type"/>.</param>
	/// <param name="payload">Serialized to JSON for the handler; null for none.</param>
	/// <param name="runAfter">The earliest time to run it; now when null.</param>
	/// <param name="userId">The user the work is for, when it is for one.</param>
	/// <returns>The job's id.</returns>
	Task<long> EnqueueAsync(
		string type,
		object? payload = null,
		DateTimeOffset? runAfter = null,
		Guid? userId = null,
		CancellationToken cancellationToken = default);
}
