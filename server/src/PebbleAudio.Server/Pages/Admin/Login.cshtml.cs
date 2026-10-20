using Microsoft.AspNetCore.Identity;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;
using PebbleAudio.Server.Auth;
using PebbleAudio.Server.Data;

namespace PebbleAudio.Server.Pages.Admin;

/// <summary>
/// Passkey-only sign-in with a discoverable credential: no user name and no password field.
/// </summary>
public sealed class LoginModel(
	SignInManager<ApplicationUser> signInManager,
	ArchiveDbContext db,
	ILogger<LoginModel> logger)
	: PageModel
{
	[BindProperty(SupportsGet = true)]
	public string? ReturnUrl { get; set; }

	/// <summary>True when sign-in is a step of an app's OAuth sign-in, which returns to the consent page.</summary>
	public bool ForConnection => ReturnUrl?.StartsWith("/oauth/", StringComparison.OrdinalIgnoreCase) == true;

	public async Task<IActionResult> OnGetAsync(CancellationToken cancellationToken)
	{
		if (!await AdminAccount.IsSetUpAsync(db, cancellationToken))
		{
			return RedirectToPage("/Admin/Setup");
		}

		if (User.Identity?.IsAuthenticated == true)
		{
			return LocalRedirect(SafeReturnUrl());
		}

		return Page();
	}

	public async Task<IActionResult> OnPostPasskeyRequestOptionsAsync()
	{
		var optionsJson = await signInManager.MakePasskeyRequestOptionsAsync(user: null);
		return Content(optionsJson, "application/json");
	}

	public async Task<IActionResult> OnPostPasskeySignInAsync(CancellationToken cancellationToken)
	{
		var credentialJson = await PasskeyRequests.ReadBodyAsync(Request, cancellationToken);
		if (credentialJson is null)
		{
			return PasskeyRequests.Error(StatusCodes.Status400BadRequest, "The browser sent no passkey.");
		}

		var result = await signInManager.PasskeySignInAsync(credentialJson);
		if (!result.Succeeded)
		{
			logger.LogInformation("A passkey sign-in did not succeed.");
			return PasskeyRequests.Error(
				StatusCodes.Status401Unauthorized,
				"That passkey didn't work here. Try again, or use another passkey.");
		}

		return PasskeyRequests.Done(SafeReturnUrl());
	}

	private string SafeReturnUrl() =>
		!string.IsNullOrWhiteSpace(ReturnUrl) && Url.IsLocalUrl(ReturnUrl) ? ReturnUrl : "/admin";
}
