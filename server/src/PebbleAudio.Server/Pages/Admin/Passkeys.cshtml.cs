using System.Buffers.Text;
using Microsoft.AspNetCore.Identity;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;
using PebbleAudio.Server.Auth;

namespace PebbleAudio.Server.Pages.Admin;

public sealed class PasskeysModel(
	SignInManager<ApplicationUser> signInManager,
	UserManager<ApplicationUser> userManager,
	ILogger<PasskeysModel> logger)
	: PageModel
{
	public IReadOnlyList<PasskeyRow> Passkeys { get; private set; } = [];

	public string? Message { get; private set; }

	/// <summary>What a passkey added from this browser is called if the name is left empty.</summary>
	public string SuggestedName => PasskeyNames.FromDevice(Request.Headers.UserAgent);

	public async Task<IActionResult> OnGetAsync()
	{
		if (await userManager.GetUserAsync(User) is not { } user)
		{
			return Challenge();
		}

		await LoadAsync(user);
		return Page();
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

		return PasskeyRequests.Done("/admin/passkeys");
	}

	public async Task<IActionResult> OnPostRemoveAsync(string id)
	{
		if (await userManager.GetUserAsync(User) is not { } user)
		{
			return Challenge();
		}

		var passkeys = await userManager.GetPasskeysAsync(user);
		if (passkeys.Count <= 1)
		{
			Message = "Add another passkey before removing this one.";
			await LoadAsync(user);
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
		return RedirectToPage();
	}

	private async Task LoadAsync(ApplicationUser user)
	{
		var passkeys = await userManager.GetPasskeysAsync(user);
		Passkeys = passkeys
			.OrderBy(p => p.CreatedAt)
			.Select(p => new PasskeyRow(
				Base64Url.EncodeToString(p.CredentialId),
				string.IsNullOrWhiteSpace(p.Name) ? "Passkey" : p.Name,
				p.CreatedAt,
				p.IsBackedUp))
			.ToList();
	}

	public sealed record PasskeyRow(string Id, string Name, DateTimeOffset CreatedAt, bool IsSynced);
}
