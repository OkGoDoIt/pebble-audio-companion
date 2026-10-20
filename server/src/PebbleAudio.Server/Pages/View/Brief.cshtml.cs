using System.Globalization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;
using PebbleAudio.Server.Data;

namespace PebbleAudio.Server.Pages.View;

/// <summary>
/// <c>/b/week/{yyyy-MM-dd}</c> and <c>/b/month/{yyyy-MM}</c>: the app's brief of a week or a month, and its days. A
/// period without a brief says so calmly and still lists its days.
/// </summary>
public sealed class BriefModel(ViewerReader viewer) : PageModel
{
	public BriefView? View { get; private set; }

	public async Task<IActionResult> OnGetAsync(string kind, string key, CancellationToken cancellationToken)
	{
		var call = await viewer.BeginAsync(User, cancellationToken);
		switch (kind)
		{
			case "week" when DateOnly.TryParseExact(key, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var day):
			{
				// Any day of a week opens that week, at its own address.
				var start = await viewer.WeekStartAsync(call, day, cancellationToken);
				if (start != day)
				{
					return Redirect(viewer.Links.Week(start));
				}

				View = await viewer.BriefAsync(call, BriefKind.Week, start, cancellationToken);
				return Page();
			}

			case "month" when DateOnly.TryParseExact($"{key}-01", "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var first):
				View = await viewer.BriefAsync(call, BriefKind.Month, first, cancellationToken);
				return Page();

			default:
				return NotFound();
		}
	}
}
