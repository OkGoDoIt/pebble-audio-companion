using System.Text.Json;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;

namespace PebbleAudio.Server.Pages.View;

/// <summary>
/// <c>/c/{conversationId}?t={seconds}</c>: one conversation, opened at a moment when a link carries one. It answers,
/// in order, what it was, when, and with whom; what was said; then where it is in the day.
/// </summary>
public sealed class ConversationModel(ViewerReader viewer) : PageModel
{
	public ConversationView? View { get; private set; }

	/// <summary>What the page's scripts draw from: the strip, the player, and the clip.</summary>
	public string ModelJson { get; private set; } = "{}";

	public async Task<IActionResult> OnGetAsync(string conversationId, int? t, CancellationToken cancellationToken)
	{
		var call = await viewer.BeginAsync(User, cancellationToken);
		View = await viewer.ConversationAsync(call, conversationId, t, cancellationToken);
		if (View is null)
		{
			Response.StatusCode = StatusCodes.Status404NotFound;
			return Page();
		}

		ModelJson = JsonSerializer.Serialize(
			new
			{
				id = View.Row.Id,
				clipUrl = $"/c/{Uri.EscapeDataString(View.Row.Id)}/clip",
				startMs = View.Row.StartedAt.ToUnixTimeMilliseconds(),
				tz = View.ZoneId,
				dur = View.DurationSec,
				t = View.T,
				maxClip = (int)call.Settings.ClipMaxDuration.TotalSeconds,
				lanes = View.Lanes.Select(l => new { name = l.Name, cls = l.Css }),
				turns = View.Turns.Select(x => new[] { x.Lane, x.S, x.E }),
				gaps = View.Marks.Select(m => new { k = m.Kind, s = m.S, e = m.E, label = m.Label }),
				clip = View.Clip,
				expiredOnPhone = View.Row.ExpiredOnPhoneAt is not null,
			},
			ViewerModule.Json);
		return Page();
	}
}
