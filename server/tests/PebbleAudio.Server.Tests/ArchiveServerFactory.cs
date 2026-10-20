using System.Collections.Concurrent;
using System.ComponentModel;
using System.Net;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Identity;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using ModelContextProtocol.Server;
using Npgsql;
using PebbleAudio.Server.Auth;
using PebbleAudio.Server.Events;
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

			// The nightly sharing-scope deletion is queued by the tests themselves, at the times they choose.
			services.Remove(services.Single(d =>
				d.ServiceType == typeof(IHostedService) && d.ImplementationType == typeof(Sync.ScopeSweepScheduler)));

			services.AddJobHandler<FlakyJobHandler>(FlakyJobHandler.Type);
			services.AddJobHandler<FailingJobHandler>(FailingJobHandler.Type);

			// Outbound HTTP (client metadata documents, webhook callbacks) goes to Http instead of the internet.
			services.AddHttpClient(ClientMetadataFetcher.HttpClientName).ConfigurePrimaryHttpMessageHandler(() => new StubHttpHandler(Http));
			services.AddHttpClient(WebhookClient.HttpClientName).ConfigurePrimaryHttpMessageHandler(() => new StubHttpHandler(Http));

			services.AddSingleton<IStartupFilter, TestSignIn>();
			services.AddMcpServer().WithTools<TestWriteTools>();
		});
	}

	/// <summary>What outbound requests get. Tests in the collection run one at a time, so they share it.</summary>
	public StubHttp Http { get; } = new();

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

/// <summary>
/// Answers outbound requests by URL. Unanswered URLs get a 404. By default it serves the live ChatGPT and Claude Code
/// metadata documents and answers claude.ai's Claude document with the challenge page some datacenter addresses get.
/// </summary>
public sealed class StubHttp
{
	public delegate HttpResponseMessage Answer(HttpRequestMessage request, byte[] body);

	private readonly ConcurrentDictionary<string, Answer> _answers = new(StringComparer.Ordinal);

	public StubHttp()
	{
		On("https://claude.ai/oauth/mcp-oauth-client-metadata", (_, _) =>
		{
			var blocked = new HttpResponseMessage(HttpStatusCode.Forbidden) { Content = new StringContent("<html>Just a moment...</html>") };
			blocked.Headers.TryAddWithoutValidation("cf-mitigated", "challenge");
			return blocked;
		});
		On("https://claude.ai/oauth/claude-code-client-metadata", (_, _) => Json(KnownDocument("claude-code.json"), maxAgeSeconds: 300));
		On("https://chatgpt.com/oauth/client.json", (_, _) => Json(KnownDocument("chatgpt.json"), maxAgeSeconds: 300));
	}

	/// <summary>Every request made, in order.</summary>
	public ConcurrentQueue<(HttpRequestMessage Request, byte[] Body)> Received { get; } = new();

	public void On(string url, Answer answer) => _answers[url] = answer;

	public static HttpResponseMessage Json(string json, int? maxAgeSeconds = null, HttpStatusCode status = HttpStatusCode.OK)
	{
		var response = new HttpResponseMessage(status) { Content = new StringContent(json, System.Text.Encoding.UTF8, "application/json") };
		if (maxAgeSeconds is { } maxAge)
		{
			response.Headers.CacheControl = new System.Net.Http.Headers.CacheControlHeaderValue { Public = true, MaxAge = TimeSpan.FromSeconds(maxAge) };
		}

		return response;
	}

	internal async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
	{
		var body = request.Content is null ? [] : await request.Content.ReadAsByteArrayAsync(cancellationToken);
		Received.Enqueue((request, body));
		return _answers.TryGetValue(request.RequestUri!.ToString(), out var answer)
			? answer(request, body)
			: new HttpResponseMessage(HttpStatusCode.NotFound);
	}

	/// <summary>The copy of a known client's metadata document that ships with the server.</summary>
	public static string KnownDocument(string fileName)
	{
		using var stream = typeof(KnownClients).Assembly.GetManifestResourceStream($"KnownClients/{fileName}")
			?? throw new InvalidOperationException($"KnownClients/{fileName} is not embedded in the server.");
		using var reader = new StreamReader(stream);
		return reader.ReadToEnd();
	}
}

/// <summary>A fresh handler per client the factory builds, so its disposal never touches the shared stub.</summary>
public sealed class StubHttpHandler(StubHttp stub) : HttpMessageHandler
{
	protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
		stub.SendAsync(request, cancellationToken);
}

/// <summary>
/// <c>GET /test/sign-in?userId=…</c> signs a browser in as that user, standing in for the passkey ceremony (which
/// AdminAccessTests covers) so OAuth tests can reach the consent page without creating the admin's first passkey.
/// </summary>
public sealed class TestSignIn : IStartupFilter
{
	public const string Path = "/test/sign-in";

	public Action<IApplicationBuilder> Configure(Action<IApplicationBuilder> next) => app =>
	{
		// Not app.Map: it moves the path into PathBase, and the sign-in cookie would be scoped to /test/sign-in.
		app.Use(async (context, nextMiddleware) =>
		{
			if (context.Request.Path != Path)
			{
				await nextMiddleware(context);
				return;
			}

			var users = context.RequestServices.GetRequiredService<UserManager<ApplicationUser>>();
			var user = await users.FindByIdAsync(context.Request.Query["userId"].ToString());
			if (user is null)
			{
				context.Response.StatusCode = StatusCodes.Status404NotFound;
				return;
			}

			await context.RequestServices.GetRequiredService<SignInManager<ApplicationUser>>().SignInAsync(user, isPersistent: false);
		});
		next(app);
	};
}

/// <summary>A tool that is not read-only, so the tests can check that writing needs <c>archive:write</c>.</summary>
[McpServerToolType]
public sealed class TestWriteTools
{
	public const string Name = "test_add_note";

	[McpServerTool(Name = Name, Title = "Add a test note", ReadOnly = false, Destructive = false, Idempotent = false, OpenWorld = false)]
	[Description("Test only: pretends to add a note.")]
	public static string AddNote() => "added";
}
