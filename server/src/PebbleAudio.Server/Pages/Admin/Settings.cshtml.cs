using System.Buffers.Text;
using System.Globalization;
using Microsoft.AspNetCore.Identity;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;
using PebbleAudio.Server.Auth;
using PebbleAudio.Server.Data;
using PebbleAudio.Server.Settings;
using PebbleAudio.Server.Sync;

namespace PebbleAudio.Server.Pages.Admin;

/// <summary>
/// <c>/settings</c>: what is left of the old admin area, on one page. How the server is doing (the old Status page), the
/// passkeys that sign you in (the old Passkeys page, with its WebAuthn handlers), what the phone shares, and the typed
/// settings with their defaults.
/// </summary>
public sealed class SettingsModel(
	SettingsService settings,
	SharingScopes scopes,
	ArchiveStatusService statusService,
	SignInManager<ApplicationUser> signInManager,
	UserManager<ApplicationUser> userManager,
	TimeProvider time,
	ILogger<SettingsModel> logger) : PageModel
{
	public const string PasskeysUrl = "/settings#passkeys";

	public ArchiveSettings Current { get; private set; } = ArchiveSettings.Defaults;

	/// <summary>What the phone shares with the server; the phone owns it, so the page only shows it.</summary>
	public AccountScope? Sharing { get; private set; }

	public ArchiveStatus Status { get; private set; } = null!;

	public IReadOnlyList<(string Label, int Count)> Counts { get; private set; } = [];

	public IReadOnlyList<PasskeyRow> Passkeys { get; private set; } = [];

	/// <summary>Why a passkey was not removed.</summary>
	public string? PasskeyMessage { get; private set; }

	[BindProperty]
	public Dictionary<string, int> Values { get; set; } = [];

	[BindProperty(SupportsGet = true)]
	public bool Saved { get; set; }

	public DateTimeOffset Now => time.GetUtcNow();

	public TimeZoneInfo Zone => Sharing?.TimeZone ?? TimeZoneInfo.Utc;

	/// <summary>What a passkey added from this browser is called if the name is left empty.</summary>
	public string SuggestedName => PasskeyNames.FromDevice(Request.Headers.UserAgent);

	/// <summary>The sharing scope in words: <c>All conversations</c>, <c>From October 21, 2026</c>, <c>The last 90 days</c>.</summary>
	public string SharingText => Sharing switch
	{
		null => "All conversations",
		{ Kind: SharingScopeKind.All } => "All conversations",
		{ Kind: SharingScopeKind.Since, Since: { } since } =>
			$"From {TimeZoneInfo.ConvertTime(since, Sharing.TimeZone).ToString("MMMM d, yyyy", SiteText.English)}",
		{ Kind: SharingScopeKind.LastDays, Days: { } days } => days == 1 ? "The last day" : $"The last {days:N0} days",
		_ => "All conversations",
	};

	/// <summary>Synced within the day: a green dot. Longer, an amber one. Never, a gray one.</summary>
	public SyncFreshness Freshness => Status.LastSyncAt switch
	{
		null => SyncFreshness.Never,
		{ } at when Now - at < TimeSpan.FromDays(1) => SyncFreshness.Recent,
		_ => SyncFreshness.Stale,
	};

	public async Task<IActionResult> OnGetAsync(CancellationToken cancellationToken)
	{
		if (await userManager.GetUserAsync(User) is not { } user)
		{
			return Challenge();
		}

		Current = await settings.GetAsync(cancellationToken);
		Values = [];
		await LoadAsync(user, cancellationToken);
		return Page();
	}

	public async Task<IActionResult> OnPostAsync(CancellationToken cancellationToken)
	{
		if (await userManager.GetUserAsync(User) is not { } user)
		{
			return Challenge();
		}

		foreach (var definition in SettingDefinition.All)
		{
			var field = $"Values[{definition.Key}]";
			if (!Values.TryGetValue(definition.Key, out var value) || value < definition.Min || value > definition.Max)
			{
				// Replaces the model binder's own wording for a value that is not a number.
				ModelState.Remove(field);
				ModelState.AddModelError(field, $"Use a whole number from {definition.Min:N0} to {definition.Max:N0}.");
			}
		}

		if (!ModelState.IsValid)
		{
			Current = await settings.GetAsync(cancellationToken);
			await LoadAsync(user, cancellationToken);
			return Page();
		}

		var known = SettingDefinition.All.Select(d => d.Key).ToHashSet(StringComparer.Ordinal);
		await settings.SaveAsync(Values.Where(v => known.Contains(v.Key)).ToDictionary(), cancellationToken);
		return Redirect("/settings?saved=true#limits");
	}

	public async Task<IActionResult> OnPostResetAsync(CancellationToken cancellationToken)
	{
		await settings.SaveAsync(SettingDefinition.All.ToDictionary(d => d.Key, d => d.Default), cancellationToken);
		return Redirect("/settings?saved=true#limits");
	}

	public async Task<IActionResult> OnPostPasskeyCreationOptionsAsync()
	{
		if (await userManager.GetUserAsync(User) is not { } user)
		{
			return PasskeyRequests.Error(StatusCodes.Status401Unauthorized, "Sign in again to add a passkey.");
		}

		var optionsJson = await signInManager.MakePasskeyCreationOptionsAsync(new PasskeyUserEntity
		{
			Id = user.Id.ToString(),
			Name = user.UserName ?? AdminAccount.UserName,
			DisplayName = AdminAccount.PasskeyDisplayName,
		});
		return Content(optionsJson, "application/json");
	}

	public async Task<IActionResult> OnPostPasskeyAttestationAsync(string? name, CancellationToken cancellationToken)
	{
		if (await userManager.GetUserAsync(User) is not { } user)
		{
			return PasskeyRequests.Error(StatusCodes.Status401Unauthorized, "Sign in again to add a passkey.");
		}

		var credentialJson = await PasskeyRequests.ReadBodyAsync(Request, cancellationToken);
		if (credentialJson is null)
		{
			return PasskeyRequests.Error(StatusCodes.Status400BadRequest, "The browser sent no passkey.");
		}

		var attestation = await signInManager.PerformPasskeyAttestationAsync(credentialJson);
		if (!attestation.Succeeded || attestation.UserEntity?.Id != user.Id.ToString())
		{
			logger.LogWarning("Adding a passkey failed: {Reason}", attestation.Failure?.Message);
			return PasskeyRequests.Error(StatusCodes.Status400BadRequest, "The passkey wasn't saved. Try again.");
		}

		attestation.Passkey.Name = PasskeyNames.Choose(name, Request.Headers.UserAgent);
		var added = await userManager.AddOrUpdatePasskeyAsync(user, attestation.Passkey);
		if (!added.Succeeded)
		{
			logger.LogWarning("Storing a passkey failed: {Errors}", string.Join("; ", added.Errors.Select(e => e.Description)));
			return PasskeyRequests.Error(StatusCodes.Status400BadRequest, "The passkey wasn't saved. Try again.");
		}

		return PasskeyRequests.Done(PasskeysUrl);
	}

	public async Task<IActionResult> OnPostRemovePasskeyAsync(string id, CancellationToken cancellationToken)
	{
		if (await userManager.GetUserAsync(User) is not { } user)
		{
			return Challenge();
		}

		var passkeys = await userManager.GetPasskeysAsync(user);
		if (passkeys.Count <= 1)
		{
			PasskeyMessage = "Add another passkey before removing this one.";
			Current = await settings.GetAsync(cancellationToken);
			await LoadAsync(user, cancellationToken);
			return Page();
		}

		byte[] credentialId;
		try
		{
			credentialId = Base64Url.DecodeFromChars(id);
		}
		catch (FormatException)
		{
			return NotFound();
		}

		await userManager.RemovePasskeyAsync(user, credentialId);
		return Redirect(PasskeysUrl);
	}

	private async Task LoadAsync(ApplicationUser user, CancellationToken cancellationToken)
	{
		Sharing = await scopes.GetAsync(user.Id, cancellationToken);
		Status = await statusService.GetAsync(user.Id, cancellationToken);
		var counts = Status.Counts;
		Counts =
		[
			("Conversations", counts.Conversations),
			("Transcripts", counts.Transcripts),
			("Day recaps", counts.Recaps),
			("Briefs", counts.Briefs),
			("Follow-ups", counts.FollowUps),
			("Notes", counts.Notes),
			("People", counts.People),
		];

		Passkeys = [.. (await userManager.GetPasskeysAsync(user))
			.OrderBy(p => p.CreatedAt)
			.Select(p => new PasskeyRow(
				Base64Url.EncodeToString(p.CredentialId),
				string.IsNullOrWhiteSpace(p.Name) ? "Passkey" : p.Name,
				p.CreatedAt,
				p.IsBackedUp))];
	}

	/// <summary>"Oct 13 – Oct 15", or one day, or null with nothing on record.</summary>
	public string? DaysOnRecord => Status.FirstDay is { } first && Status.LastDay is { } last
		? first == last ? Day(first) : $"{Day(first)} – {Day(last)}"
		: null;

	private string Day(DateOnly day) =>
		day.ToString(day.Year == DateOnly.FromDateTime(Now.UtcDateTime).Year ? "MMM d" : "MMM d, yyyy", CultureInfo.GetCultureInfo("en-US"));

	public enum SyncFreshness
	{
		Never,
		Recent,
		Stale,
	}

	public sealed record PasskeyRow(string Id, string Name, DateTimeOffset CreatedAt, bool IsSynced);
}
