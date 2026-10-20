using System.Text.Json;
using PebbleAudio.Server.Data;

namespace PebbleAudio.Server.Jobs;

public sealed class JobQueue(
	ArchiveDbContext db,
	TimeProvider time,
	JobSignal signal,
	IServiceProviderIsKeyedService keyedServices)
	: IJobQueue
{
	public async Task<long> EnqueueAsync(
		string type,
		object? payload = null,
		DateTimeOffset? runAfter = null,
		Guid? userId = null,
		CancellationToken cancellationToken = default)
	{
		if (!keyedServices.IsKeyedService(typeof(IJobHandler), type))
		{
			throw new ArgumentException($"No job handler is registered for '{type}'.", nameof(type));
		}

		var now = time.GetUtcNow();
		var job = new Job
		{
			UserId = userId,
			Type = type,
			Payload = payload is null ? null : JsonSerializer.SerializeToDocument(payload, JsonSerializerOptions.Web),
			State = JobState.Pending,
			RunAfter = (runAfter ?? now).ToUniversalTime(),
			CreatedAt = now,
		};

		db.Jobs.Add(job);
		await db.SaveChangesAsync(cancellationToken);
		signal.Wake();
		return job.Id;
	}
}
