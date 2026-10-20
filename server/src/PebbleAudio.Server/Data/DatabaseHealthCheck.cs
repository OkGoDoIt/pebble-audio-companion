using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Diagnostics.HealthChecks;

namespace PebbleAudio.Server.Data;

/// <summary>
/// <c>/healthz</c> is healthy only when Postgres answers a query within two seconds.
/// </summary>
public sealed class DatabaseHealthCheck(ArchiveDbContext db) : IHealthCheck
{
	public async Task<HealthCheckResult> CheckHealthAsync(HealthCheckContext context, CancellationToken cancellationToken = default)
	{
		using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
		timeout.CancelAfter(TimeSpan.FromSeconds(2));

		try
		{
			await db.Database.ExecuteSqlRawAsync("SELECT 1", timeout.Token);
			return HealthCheckResult.Healthy();
		}
		catch (Exception ex) when (ex is not OperationCanceledException || !cancellationToken.IsCancellationRequested)
		{
			return HealthCheckResult.Unhealthy("The database did not answer.", ex);
		}
	}
}
