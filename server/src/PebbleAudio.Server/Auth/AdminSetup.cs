using System.Security.Cryptography;
using System.Text;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;
using PebbleAudio.Server.Data;

namespace PebbleAudio.Server.Auth;

/// <summary>
/// The single admin account and how it comes to exist.
/// </summary>
public static class AdminAccount
{
	public const string UserName = "admin";

	/// <summary>
	/// What password managers show next to the passkey.
	/// </summary>
	public const string PasskeyDisplayName = "Pebble Audio admin";

	/// <summary>
	/// Setup is done once a passkey exists. Until then <c>/setup</c> is open to whoever has the code.
	/// </summary>
	public static Task<bool> IsSetUpAsync(ArchiveDbContext db, CancellationToken cancellationToken) =>
		db.UserPasskeys.AnyAsync(cancellationToken);
}

/// <summary>
/// The one-time setup code for the first passkey: a fresh code printed to the log at every start, and
/// optionally a fixed one from <c>PebbleAudio__SetupCode</c>. Either is accepted until setup is done.
/// </summary>
public sealed class SetupCodes(IOptions<PebbleAudioOptions> options)
{
	private const string Alphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";

	/// <summary>
	/// The code printed to the log, for example <c>K7QM-3XWD</c>.
	/// </summary>
	public string Generated { get; } = Generate();

	public bool Matches(string? candidate)
	{
		var normalized = Normalize(candidate);
		if (normalized.Length == 0)
		{
			return false;
		}

		var matchesGenerated = FixedTimeEquals(normalized, Normalize(Generated));
		var configured = Normalize(options.Value.SetupCode);
		var matchesConfigured = configured.Length > 0 && FixedTimeEquals(normalized, configured);
		return matchesGenerated | matchesConfigured;
	}

	private static string Generate()
	{
		var characters = RandomNumberGenerator.GetItems<char>(Alphabet, 8);
		return $"{new string(characters, 0, 4)}-{new string(characters, 4, 4)}";
	}

	private static string Normalize(string? code) =>
		new((code ?? "").Where(char.IsLetterOrDigit).Select(char.ToUpperInvariant).ToArray());

	private static bool FixedTimeEquals(string left, string right) =>
		CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(left), Encoding.UTF8.GetBytes(right));
}

/// <summary>
/// Prints the setup code at startup while no admin passkey exists.
/// </summary>
public sealed class SetupAnnouncer(
	IServiceScopeFactory scopes,
	SetupCodes codes,
	IOptions<PebbleAudioOptions> options,
	ILogger<SetupAnnouncer> logger)
	: IHostedService
{
	public async Task StartAsync(CancellationToken cancellationToken)
	{
		var setupUrl = $"{options.Value.PublicOrigin}/setup";
		try
		{
			await using var scope = scopes.CreateAsyncScope();
			var db = scope.ServiceProvider.GetRequiredService<ArchiveDbContext>();
			if (await AdminAccount.IsSetUpAsync(db, cancellationToken))
			{
				return;
			}

			logger.LogWarning(
				"No admin passkey exists yet. Open {SetupUrl} and enter the setup code {SetupCode}.",
				setupUrl,
				codes.Generated);
		}
		catch (Exception ex) when (ex is not OperationCanceledException)
		{
			logger.LogWarning(
				ex,
				"Could not check for an admin passkey. If setup is not done, open {SetupUrl} and enter the setup code {SetupCode}.",
				setupUrl,
				codes.Generated);
		}
	}

	public Task StopAsync(CancellationToken cancellationToken) => Task.CompletedTask;
}
