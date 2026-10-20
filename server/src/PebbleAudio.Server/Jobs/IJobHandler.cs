using System.Text.Json;

namespace PebbleAudio.Server.Jobs;

/// <summary>
/// Runs one type of job. Registered with <see cref="JobServiceCollectionExtensions.AddJobHandler{THandler}"/>
/// and resolved in a fresh scope for every attempt. Throwing fails the attempt; the queue retries it with
/// backoff and sets it aside after the configured number of attempts, so a handler must be safe to rerun.
/// </summary>
public interface IJobHandler
{
	Task RunAsync(JobContext job, CancellationToken cancellationToken);
}

/// <summary>
/// The job a handler is running.
/// </summary>
/// <param name="Id">The job's id.</param>
/// <param name="Type">The handler's registered name.</param>
/// <param name="Payload">The payload it was enqueued with, if any.</param>
/// <param name="Attempt">1 on the first run, 2 on the first retry, and so on.</param>
/// <param name="UserId">The user the work is for, if any.</param>
public sealed record JobContext(long Id, string Type, JsonElement? Payload, int Attempt, Guid? UserId)
{
	public T GetPayload<T>() =>
		Payload is { } payload
			? payload.Deserialize<T>(JsonSerializerOptions.Web)
				?? throw new InvalidOperationException($"Job {Id} has an empty payload.")
			: throw new InvalidOperationException($"Job {Id} has no payload.");
}
