using System.Runtime.InteropServices;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.DataProtection;
using Microsoft.AspNetCore.HttpOverrides;
using Microsoft.AspNetCore.Identity;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Hosting.Systemd;
using Microsoft.Extensions.Options;
using ModelContextProtocol;
using ModelContextProtocol.AspNetCore;
using ModelContextProtocol.AspNetCore.Authentication;
using ModelContextProtocol.Authentication;
using PebbleAudio.Server;
using PebbleAudio.Server.Auth;
using PebbleAudio.Server.Data;
using PebbleAudio.Server.Events;
using PebbleAudio.Server.Jobs;
using PebbleAudio.Server.Mcp;
using PebbleAudio.Server.Pages;
using PebbleAudio.Server.Settings;

var builder = WebApplication.CreateBuilder(args);

// Under systemd (Type=notify) this sends READY/STOPPING and logs in journald's format; elsewhere it does nothing.
builder.Host.UseSystemd();

builder.WebHost.ConfigureKestrel(options =>
{
	// Same ceiling as nginx's client_max_body_size: clip uploads and sync batches are the large bodies.
	options.Limits.MaxRequestBodySize = 64L * 1024 * 1024;
});

var connectionString = builder.Configuration.GetConnectionString("DefaultConnection")
	?? throw new InvalidOperationException("ConnectionStrings:DefaultConnection is missing.");
var publicOrigin = PebbleAudioOptions.ReadPublicOrigin(builder.Configuration);

builder.Services.Configure<PebbleAudioOptions>(builder.Configuration.GetSection(PebbleAudioOptions.SectionName));
builder.Services.PostConfigure<PebbleAudioOptions>(options => options.PublicOrigin = publicOrigin);

var keysPath = builder.Configuration["DataProtection:KeysPath"];
if (string.IsNullOrWhiteSpace(keysPath))
{
	if (!builder.Environment.IsDevelopment())
	{
		throw new InvalidOperationException("DataProtection:KeysPath is missing; sign-in cookies would not survive a restart.");
	}

	keysPath = Path.Combine(builder.Environment.ContentRootPath, "App_Data", "data-protection-keys");
}

Directory.CreateDirectory(keysPath);
builder.Services.AddDataProtection()
	.PersistKeysToFileSystem(new DirectoryInfo(keysPath))
	.SetApplicationName("PebbleAudio");

// nginx on the same machine is the only proxy; loopback proxies are trusted by default.
builder.Services.Configure<ForwardedHeadersOptions>(options =>
{
	options.ForwardedHeaders = ForwardedHeaders.XForwardedFor | ForwardedHeaders.XForwardedProto;
	options.ForwardLimit = 1;
});

builder.Services.AddDbContext<ArchiveDbContext>(options =>
	options.UseNpgsql(connectionString, npgsql =>
		npgsql.UseQuerySplittingBehavior(QuerySplittingBehavior.SplitQuery)));

builder.Services.AddHealthChecks()
	.AddCheck<DatabaseHealthCheck>("database");

// Passkeys are the only way into the admin area (ASP.NET Core Identity, schema version 3).
builder.Services.Configure<IdentityPasskeyOptions>(options =>
{
	options.ResidentKeyRequirement = "required";
	options.UserVerificationRequirement = "required";
	options.AttestationConveyancePreference = "none";
	options.ChallengeSize = 32;
});

builder.Services.AddAntiforgery(options => options.HeaderName = "RequestVerificationToken");

builder.Services.AddIdentity<ApplicationUser, IdentityRole<Guid>>(options =>
	{
		options.Stores.SchemaVersion = IdentitySchemaVersions.Version3;
		options.User.RequireUniqueEmail = false;
		options.SignIn.RequireConfirmedAccount = false;
	})
	.AddEntityFrameworkStores<ArchiveDbContext>()
	.AddDefaultTokenProviders();

builder.Services.ConfigureApplicationCookie(options =>
{
	// The cookie keeps its old name, so nobody is signed out by the move from /admin to the site's own pages.
	options.Cookie.Name = "pebbleaudio.admin";
	options.LoginPath = "/sign-in";
	options.LogoutPath = "/sign-out";
	options.AccessDeniedPath = "/sign-in";
});

// The cookie stays the app's default scheme. Bearer tokens and the MCP challenge apply only to /mcp,
// through ArchiveAuth.McpPolicy, so admin pages keep redirecting to the login page.
builder.Services.AddAuthentication()
	.AddScheme<AuthenticationSchemeOptions, BearerTokenHandler>(ArchiveAuth.BearerScheme, _ => { })
	.AddMcp(options =>
	{
		// Built from the configured origin, not the request's host, so the challenge cannot be steered.
		options.ResourceMetadataUri = new Uri($"{publicOrigin}/.well-known/oauth-protected-resource/mcp");
		options.ResourceMetadata = new ProtectedResourceMetadata
		{
			Resource = $"{publicOrigin}/mcp",
			AuthorizationServers = [publicOrigin],
			ScopesSupported = [ArchiveScopes.Read, ArchiveScopes.Write],
			ResourceName = "Pebble Audio",
		};
	});

builder.Services.AddAuthorizationBuilder()
	.AddPolicy(ArchiveAuth.McpPolicy, policy => policy
		.AddAuthenticationSchemes(McpAuthenticationDefaults.AuthenticationScheme)
		.RequireAuthenticatedUser()
		.RequireClaim(ArchiveAuth.ScopeClaim, ArchiveScopes.Read));

builder.Services.AddMcpServer(options =>
	{
		options.ServerInfo = new() { Name = "Pebble Audio", Title = "Pebble Audio", Version = AppVersion.Display };
		options.ServerInstructions = Instructions.Text;
	})
	.WithHttpTransport(options => options.SessionMode = HttpServerSessionMode.Stateless)
	.WithArchive();

builder.Services.TryAddSingleton(TimeProvider.System);
builder.Services.AddHttpContextAccessor();
builder.Services.AddScoped<ApiTokenService>();
builder.Services.AddScoped<ArchiveStatusService>();
builder.Services.AddScoped<AiReadLog>();
builder.Services.AddScoped<SettingsService>();
builder.Services.AddSingleton<SetupCodes>();
builder.Services.AddHostedService<SetupAnnouncer>();
builder.Services.AddJobQueue()
	.AddJobHandler<NoopJobHandler>(NoopJobHandler.Type);
builder.Services.AddSync();
builder.Services.AddOAuthServer();
builder.Services.AddMcpEvents();
builder.Services.AddViewer();

builder.Services.AddRazorPages(options =>
{
	options.Conventions.AuthorizeFolder("/Admin");
	options.Conventions.AuthorizeFolder("/View");
	options.Conventions.AllowAnonymousToPage("/Admin/Login");
	options.Conventions.AllowAnonymousToPage("/Admin/Setup");
});
builder.Services.Configure<RouteOptions>(options => options.LowercaseUrls = true);

var app = builder.Build();

if (SystemdHelpers.IsSystemdService())
{
	// The unit stops the service with SIGINT, but SystemdLifetime only listens for SIGTERM. Without this the
	// process would exit on SIGINT without draining requests or handing running jobs back to the queue.
	var lifetime = app.Services.GetRequiredService<IHostApplicationLifetime>();
	var sigint = PosixSignalRegistration.Create(PosixSignal.SIGINT, context =>
	{
		context.Cancel = true;
		lifetime.StopApplication();
	});
	lifetime.ApplicationStopped.Register(sigint.Dispose);
}

app.UseForwardedHeaders();

if (!app.Environment.IsDevelopment())
{
	app.UseExceptionHandler("/Error");
	app.UseHsts();
}

app.UseRouting();
app.UseCors();
app.UseAuthentication();
app.UseAuthorization();

if (app.Configuration.GetValue<bool>("Database:MigrateOnStartup"))
{
	await using var scope = app.Services.CreateAsyncScope();
	await scope.ServiceProvider.GetRequiredService<ArchiveDbContext>().Database.MigrateAsync();
}

app.MapHealthChecks("/healthz");

app.MapViewer();

// The SDK serves the protected-resource metadata at /.well-known/oauth-protected-resource/mcp; some clients
// look at the root path first, so it answers there too.
app.MapGet("/.well-known/oauth-protected-resource", (IOptionsMonitor<McpAuthenticationOptions> options) =>
	Results.Json(
		options.Get(McpAuthenticationDefaults.AuthenticationScheme).ResourceMetadata,
		McpJsonUtilities.DefaultOptions))
	.RequireCors(BrowserClients.CorsPolicy);

app.MapMcp("/mcp").RequireAuthorization(ArchiveAuth.McpPolicy).RequireCors(BrowserClients.CorsPolicy);
app.MapSync();
app.MapOAuthServer();
app.MapOldAdminUrls();

app.MapStaticAssets();
app.MapRazorPages()
	.WithStaticAssets();

app.Run();

/// <summary>
/// The entry point, public so the test host can start the app.
/// </summary>
public partial class Program;
