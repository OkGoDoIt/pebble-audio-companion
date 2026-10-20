using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Npgsql;
using PebbleAudio.Server.Jobs;

namespace PebbleAudio.Server.Tests;

/// <summary>
/// One test host for the whole suite, on a real Postgres database created for the run and dropped after it.
/// Point <c>PEBBLEAUDIO_TEST_POSTGRES</c> at a server where the user may create databases; by default it is
/// the local Postgres as the current OS user.
/// </summary>
public sealed class ArchiveServerFactory : WebApplicationFactory<Program>, IAsyncLifetime
{
	public const string PublicOrigin = "http://localhost";

	private readonly string _databaseName = $"pebbleaudio_test_{Guid.NewGuid():N}";
	private readonly string _keysPath = Path.Combine(Path.GetTempPath(), "pebbleaudio-tests", Guid.NewGuid().ToString("N"));

	/// <summary>Where this run's clip audio goes; removed with the database.</summary>
	public string ClipsPath { get; } = Path.Combine(Path.GetTempPath(), "pebbleaudio-tests", Guid.NewGuid().ToString("N"), "clips");

	private static string AdminConnectionString =>
		Environment.GetEnvironmentVariable("PEBBLEAUDIO_TEST_POSTGRES")
		?? $"Host=localhost;Database=postgres;Username={Environment.UserName}";

	public string ConnectionString =>
		new NpgsqlConnectionStringBuilder(AdminConnectionString) { Database = _databaseName }.ConnectionString;

	public async Task InitializeAsync()
	{
		await using var connection = new NpgsqlConnection(AdminConnectionString);
		await connection.OpenAsync();
		await using var command = new NpgsqlCommand($"CREATE DATABASE \"{_databaseName}\"", connection);
		await command.ExecuteNonQueryAsync();

		// Starting the host applies the migrations (Database:MigrateOnStartup), the same path as development.
		_ = Services;
	}

	protected override void ConfigureWebHost(IWebHostBuilder builder)
	{
		builder.UseEnvironment("Testing");
		builder.UseSetting("ConnectionStrings:DefaultConnection", ConnectionString);
		builder.UseSetting("PebbleAudio:PublicOrigin", PublicOrigin);
		builder.UseSetting("DataProtection:KeysPath", _keysPath);
		builder.UseSetting("PebbleAudio:ClipsPath", ClipsPath);
		builder.UseSetting("Database:MigrateOnStartup", "true");

		builder.ConfigureTestServices(services =>
		{
			// The tests drive the queue through JobRunner, so the background worker stays off.
			var worker = services.Single(d =>
				d.ServiceType == typeof(IHostedService) && d.ImplementationType == typeof(JobWorker));
			services.Remove(worker);

			services.AddJobHandler<FlakyJobHandler>(FlakyJobHandler.Type);
			services.AddJobHandler<FailingJobHandler>(FailingJobHandler.Type);
		});
	}

	async Task IAsyncLifetime.DisposeAsync()
	{
		await DisposeAsync();
		NpgsqlConnection.ClearAllPools();

		await using var connection = new NpgsqlConnection(AdminConnectionString);
		await connection.OpenAsync();
		await using var command = new NpgsqlCommand($"DROP DATABASE IF EXISTS \"{_databaseName}\" WITH (FORCE)", connection);
		await command.ExecuteNonQueryAsync();

		if (Directory.Exists(_keysPath))
		{
			Directory.Delete(_keysPath, recursive: true);
		}

		var clipsRun = Path.GetDirectoryName(ClipsPath)!;
		if (Directory.Exists(clipsRun))
		{
			Directory.Delete(clipsRun, recursive: true);
		}
	}
}

[CollectionDefinition(Name)]
public sealed class ServerCollection : ICollectionFixture<ArchiveServerFactory>
{
	public const string Name = "server";
}

/// <summary>Fails its first attempt, then succeeds.</summary>
public sealed class FlakyJobHandler : IJobHandler
{
	public const string Type = "test.flaky";

	public Task RunAsync(JobContext job, CancellationToken cancellationToken) =>
		job.Attempt == 1 ? throw new InvalidOperationException("First attempts always fail.") : Task.CompletedTask;
}

/// <summary>Fails every attempt.</summary>
public sealed class FailingJobHandler : IJobHandler
{
	public const string Type = "test.failing";

	public Task RunAsync(JobContext job, CancellationToken cancellationToken) =>
		throw new InvalidOperationException("This job never works.");
}
