using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;
using Microsoft.Extensions.Options;
using PebbleAudio.Server.Auth;
using PebbleAudio.Server.Data;
using PebbleAudio.Server.Sync;

namespace PebbleAudio.Server.Pages.Admin;

public sealed class PhonesModel(PhoneLinkService links, ArchiveWipe wipe, IOptions<PebbleAudioOptions> options) : PageModel
{
	public IReadOnlyList<Device> Phones { get; private set; } = [];

	/// <summary>The code just minted, shown once with its QR code.</summary>
	public LinkInvitation? Invitation { get; private set; }

	/// <summary>What to type in the app's Server field: the host alone for https, the whole origin otherwise.</summary>
	public string ServerAddress
	{
		get
		{
			var origin = new Uri(options.Value.PublicOrigin);
			return origin.Scheme == Uri.UriSchemeHttps ? origin.Authority : options.Value.PublicOrigin;
		}
	}

	public async Task OnGetAsync(CancellationToken cancellationToken) => await LoadAsync(cancellationToken);

	public async Task<IActionResult> OnPostLinkAsync(CancellationToken cancellationToken)
	{
		var minted = await links.MintAsync(CurrentUserId(), cancellationToken);
		var url = PhoneLinkService.InvitationUrl(minted.Code, options.Value.PublicOrigin);
		Invitation = new LinkInvitation(
			PhoneLinkService.Display(minted.Code),
			url,
			LinkQrCode.Svg(url, "Code to link a phone"),
			minted.ExpiresAt);
		await LoadAsync(cancellationToken);
		return Page();
	}

	public async Task<IActionResult> OnPostRenameAsync(Guid id, string? name, CancellationToken cancellationToken)
	{
		await links.RenameAsync(CurrentUserId(), id, name, cancellationToken);
		return RedirectToPage();
	}

	public async Task<IActionResult> OnPostUnlinkAsync(Guid id, CancellationToken cancellationToken)
	{
		await wipe.UnlinkFromAdminAsync(CurrentUserId(), id, cancellationToken);
		return RedirectToPage();
	}

	private async Task LoadAsync(CancellationToken cancellationToken) =>
		Phones = await links.ListAsync(CurrentUserId(), cancellationToken);

	private Guid CurrentUserId() =>
		User.UserId() ?? throw new InvalidOperationException("The admin page requires a signed-in user.");

	/// <param name="Code">The code as shown, <c>K7QM-3XWD</c>.</param>
	/// <param name="Url">The <c>pebbleaudio://link</c> link the QR code carries.</param>
	/// <param name="QrSvg">The QR code as inline SVG.</param>
	/// <param name="ExpiresAt">When the code stops working.</param>
	public sealed record LinkInvitation(string Code, string Url, string QrSvg, DateTimeOffset ExpiresAt);
}
