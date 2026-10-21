using Microsoft.AspNetCore.Identity;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;
using PebbleAudio.Server.Auth;
using PebbleAudio.Server.Data;

namespace PebbleAudio.Server.Pages.Admin;

/// <summary>
/// First run: with the setup code, register the first passkey and create the single admin user. Once a
/// passkey exists, every handler here answers 404.
/// </summary>
public sealed class SetupModel(
	SignInManager<ApplicationUser> signInManager,
	UserManager<ApplicationUser> userManager,
	ArchiveDbContext db,
	SetupCodes setupCodes,
	TimeProvider time,
	ILogger<SetupModel> logger)
	: PageModel
{
	public const string SetupCodeHeader = "X-Setup-Code";

	public async Task<IActionResult> OnGetAsync(CancellationToken cancellationToken) =>
		await AdminAccount.IsSetUpAsync(db, cancellationToken) ? NotFound() : Page();

	public async Task<IActionResult> OnPostPasskeyCreationOptionsAsync(CancellationToken cancellationToken)
	{
		if (await RefuseAsync(cancellationToken) is { } refusal)
		{
			return refusal;
		}

		// The user is created only after the passkey is verified, so an abandoned attempt leaves nothing behind.
		var optionsJson = await signInManager.MakePasskeyCreationOptionsAsync(new PasskeyUserEntity
		{
			Id = Guid.CreateVersion7().ToString(),
			Name = AdminAccount.UserName,
			DisplayName = AdminAccount.PasskeyDisplayName,
		});
		return Content(optionsJson, "application/json");
	}

	public async Task<IActionResult> OnPostPasskeyAttestationAsync(CancellationToken cancellationToken)
	{
		if (await RefuseAsync(cancellationToken) is { } refusal)
		{
			return refusal;
		}

		var credentialJson = await PasskeyRequests.ReadBodyAsync(Request, cancellationToken);
		if (credentialJson is null)
		{
			return PasskeyRequests.Error(StatusCodes.Status400BadRequest, "The browser sent no passkey.");
		}

		var attestation = await signInManager.PerformPasskeyAttestationAsync(credentialJson);
		if (!attestation.Succeeded || !Guid.TryParse(attestation.UserEntity?.Id, out var userId))
		{
			logger.LogWarning("Setup passkey attestation failed: {Reason}", attestation.Failure?.Message);
			return PasskeyRequests.Error(StatusCodes.Status400BadRequest, "The passkey wasn't saved. Try again.");
		}

		var user = new ApplicationUser
		{
			Id = userId,
			UserName = AdminAccount.UserName,
			CreatedAt = time.GetUtcNow(),
		};
		var created = await userManager.CreateAsync(user);
		if (!created.Succeeded)
		{
			logger.LogWarning("Creating the admin user failed: {Errors}", string.Join("; ", created.Errors.Select(e => e.Description)));
			return PasskeyRequests.Error(StatusCodes.Status400BadRequest, "The admin account couldn't be created. Try again.");
		}

		attestation.Passkey.Name = PasskeyNames.Choose(null, Request.Headers.UserAgent);
		var added = await userManager.AddOrUpdatePasskeyAsync(user, attestation.Passkey);
		if (!added.Succeeded)
		{
			logger.LogWarning("Storing the setup passkey failed: {Errors}", string.Join("; ", added.Errors.Select(e => e.Description)));
			await userManager.DeleteAsync(user);
			return PasskeyRequests.Error(StatusCodes.Status400BadRequest, "The passkey wasn't saved. Try again.");
		}

		await signInManager.SignInAsync(user, isPersistent: false);
		logger.LogInformation("Setup is done: the admin account and its first passkey exist.");
		return PasskeyRequests.Done("/phones");
	}

	private async Task<IActionResult?> RefuseAsync(CancellationToken cancellationToken)
	{
		if (await AdminAccount.IsSetUpAsync(db, cancellationToken))
		{
			return NotFound();
		}

		if (!setupCodes.Matches(Request.Headers[SetupCodeHeader]))
		{
			return PasskeyRequests.Error(
				StatusCodes.Status403Forbidden,
				"That setup code doesn't match. The current one is in the server log.");
		}

		return null;
	}
}
