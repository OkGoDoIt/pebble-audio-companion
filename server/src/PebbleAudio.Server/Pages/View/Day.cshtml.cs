using System.Globalization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;

namespace PebbleAudio.Server.Pages.View;

/// <summary><c>/d/{yyyy-MM-dd}</c>: one logical day (5 AM to 5 AM): its recap, how it was covered, and its conversations.</summary>
public sealed class DayModel(ViewerReader viewer) : PageModel
{
	public DayView? View { get; private set; }

	public async Task<IActionResult> OnGetAsync(string dayKey, CancellationToken cancellationToken)
	{
		if (!DateOnly.TryParseExact(dayKey, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var day))
		{
			return NotFound();
		}

		var call = await viewer.BeginAsync(User, cancellationToken);
		View = await viewer.DayAsync(call, day, cancellationToken);
		return Page();
	}

	public string DayUrl(DateOnly day) => viewer.Links.Day(day);
}
