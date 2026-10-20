using Microsoft.AspNetCore.Mvc.RazorPages;
using Microsoft.Extensions.Options;
using PebbleAudio.Server.Sync;

namespace PebbleAudio.Server.Pages;

/// <summary>
/// <c>GET /link?code=…</c>: what the QR code on the Phones page opens when Pebble Audio is not on this iPhone (with the
/// app, the universal link opens the app instead). It shows the code to type in by hand. The code is not looked up:
/// the page says nothing about whether it is still good.
/// </summary>
public sealed class LinkModel(IOptions<PebbleAudioOptions> options) : PageModel
{
	/// <summary>The code as the Phones page shows it, <c>K7QM-3XWD</c>; null when the link carries none.</summary>
	public string? Code { get; private set; }

	public string Host => new Uri(options.Value.PublicOrigin).Authority;

	public void OnGet(string? code)
	{
		var normalized = PhoneLinkService.Normalize(code);
		Code = normalized.Length == SyncProtocol.LinkCodeLength ? PhoneLinkService.Display(normalized) : null;
		Response.Headers.CacheControl = "no-store";
	}
}
