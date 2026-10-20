using Microsoft.AspNetCore.Mvc.RazorPages;

namespace PebbleAudio.Server.Pages.View;

/// <summary><c>/</c>: the recent days, newest first, each leading with what the day was about.</summary>
public sealed class IndexModel(ViewerReader viewer) : PageModel
{
	public HomeView? View { get; private set; }

	public async Task OnGetAsync(CancellationToken cancellationToken)
	{
		var call = await viewer.BeginAsync(User, cancellationToken);
		View = await viewer.HomeAsync(call, cancellationToken);
	}
}
