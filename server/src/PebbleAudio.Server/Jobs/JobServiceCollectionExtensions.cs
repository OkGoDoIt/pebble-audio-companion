using Microsoft.Extensions.DependencyInjection.Extensions;

namespace PebbleAudio.Server.Jobs;

public static class JobServiceCollectionExtensions
{
	/// <summary>
	/// Adds the queue, its runner, and the background worker.
	/// </summary>
	public static IServiceCollection AddJobQueue(this IServiceCollection services)
	{
		services.TryAddSingleton(TimeProvider.System);
		services.AddSingleton<JobSignal>();
		services.AddSingleton<JobRunner>();
		services.AddScoped<IJobQueue, JobQueue>();
		services.AddHostedService<JobWorker>();
		return services;
	}

	/// <summary>
	/// Registers the handler for one job type.
	/// </summary>
	public static IServiceCollection AddJobHandler<THandler>(this IServiceCollection services, string type)
		where THandler : class, IJobHandler
	{
		services.AddKeyedScoped<IJobHandler, THandler>(type);
		return services;
	}
}
