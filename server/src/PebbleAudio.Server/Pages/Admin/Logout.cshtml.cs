using Microsoft.AspNetCore.Identity;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;
using PebbleAudio.Server.Auth;

namespace PebbleAudio.Server.Pages.Admin;

public sealed class LogoutModel(SignInManager<ApplicationUser> signInManager) : PageModel
{
	public IActionResult OnGet() => Redirect("/");

	public async Task<IActionResult> OnPostAsync()
	{
		await signInManager.SignOutAsync();
		return RedirectToPage("/Admin/Login");
	}
}
