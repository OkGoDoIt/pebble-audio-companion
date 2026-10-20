using Microsoft.AspNetCore.Mvc.RazorPages;
using PebbleAudio.Server.Settings;

namespace PebbleAudio.Server.Pages;

/// <summary>
/// <c>/privacy</c>, the plugin manifest's privacy policy: what this server holds, who can read it, and how it goes.
/// Every sentence is something the code does; the numbers come from the settings and the backup script.
/// </summary>
public sealed class PrivacyModel(SettingsService settings) : PageModel
{
	/// <summary>How long the backup script and the deploy keep database dumps (deploy/scripts).</summary>
	public const int BackupDays = 14;

	public int ClipKeepDays { get; private set; }

	public async Task OnGetAsync(CancellationToken cancellationToken) =>
		ClipKeepDays = (await settings.GetAsync(cancellationToken)).ClipKeepDays;
}
