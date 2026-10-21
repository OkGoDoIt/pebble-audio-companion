using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;
using Microsoft.Extensions.Options;
using PebbleAudio.Server.Auth;
using PebbleAudio.Server.Data;
using PebbleAudio.Server.Mcp;
using PebbleAudio.Server.Sync;

namespace PebbleAudio.Server.Pages.Admin;

/// <summary>
/// <c>/phones</c>, Link a phone: a one-time code with its QR code for the iPhone app's camera (round-3 03a is the
/// phone's side), and the linked phones, each renamed or unlinked here. Unlinking the last phone clears the server, as
/// unlinking on the phone does.
/// </summary>
public sealed class PhonesModel(
	PhoneLinkService links,
	ArchiveWipe wipe,
	IConnectedAssistants assistants,
	SharingScopes scopes,
	IOptions<PebbleAudioOptions> options,
	TimeProvider time) : PageModel
{
	public IReadOnlyList<Device> Phones { get; private set; } = [];

	/// <summary>The code just minted, shown once with its QR code.</summary>
	public LinkInvitation? Invitation { get; private set; }

	/// <summary>The assistants that lose access when the last phone is unlinked.</summary>
	public IReadOnlyList<string> AssistantNames { get; private set; } = [];

	public DateTimeOffset Now => time.GetUtcNow();

	public TimeZoneInfo Zone { get; private set; } = TimeZoneInfo.Utc;

	public string Host => new Uri(options.Value.PublicOrigin).Authority;

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
		Response.Headers.CacheControl = "no-store";
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

	/// <summary>"Version 1.4 (812) · Synced 3 min ago".</summary>
	public string Line(Device phone)
	{
		var parts = new List<string>();
		if (phone.AppVersion is { } version)
		{
			parts.Add($"Version {version}{(phone.AppBuild is { } build ? $" ({build})" : "")}");
		}

		parts.Add(phone.LastBatchAt is { } synced ? $"Synced {SiteText.Ago(synced, Now, Zone)}" : $"Linked {SiteText.ShortDay(phone.LinkedAt, Zone)}, not synced yet");
		return string.Join(" · ", parts);
	}

	/// <summary>"ChatGPT, Claude, and Codex on Mac lose access." for unlinking the last phone, or nothing.</summary>
	public string? LoseAccessLine => AssistantNames.Count == 0 ? null : $"{Speak.List(AssistantNames)} lose{(AssistantNames.Count == 1 ? "s" : "")} access.";

	private async Task LoadAsync(CancellationToken cancellationToken)
	{
		var userId = CurrentUserId();
		Phones = await links.ListAsync(userId, cancellationToken);
		Zone = (await scopes.GetAsync(userId, cancellationToken)).TimeZone;
		AssistantNames = [.. (await assistants.ListAsync(userId, cancellationToken)).Select(a => a.Name).Distinct()];
	}

	private Guid CurrentUserId() =>
		User.UserId() ?? throw new InvalidOperationException("Link a phone requires a signed-in user.");

	/// <param name="Code">The code as shown, <c>K7QM-3XWD</c>.</param>
	/// <param name="Url">The <c>/link?code=…</c> universal link the QR code carries.</param>
	/// <param name="QrSvg">The QR code as inline SVG.</param>
	/// <param name="ExpiresAt">When the code stops working.</param>
	public sealed record LinkInvitation(string Code, string Url, string QrSvg, DateTimeOffset ExpiresAt);
}
