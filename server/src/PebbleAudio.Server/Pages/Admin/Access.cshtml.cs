using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;
using PebbleAudio.Server.Auth;
using PebbleAudio.Server.Data;
using PebbleAudio.Server.Events;
using PebbleAudio.Server.Plugin;
using PebbleAudio.Server.Sync;

namespace PebbleAudio.Server.Pages.Admin;

/// <summary>
/// <c>/access</c>, Who can read: every assistant that can read the archive right now, from the same list the phone
/// shows (<c>GET /sync/status</c>, <c>access</c>), each with what it may do, when it last read, and Disconnect. Assistants
/// that signed in come first; access keys (<c>pat_…</c>, for tools that can't sign in) are their own group. The Pebble
/// plugin is not an assistant (it shows recording status on watch faces, and is set up from the phone), so it has a
/// group of its own after them. Below are the updates assistants asked for (MCP Events subscriptions) and apps that
/// registered once but have no access.
/// </summary>
public sealed class AccessModel(
	IConnectedAssistants assistants,
	OAuthConnections connections,
	EventSubscriptions subscriptions,
	PhoneRequestService requests,
	SharingScopes scopes,
	TimeProvider time) : PageModel
{
	/// <summary>Assistants that signed in with the passkey (OAuth), most recently used first.</summary>
	public IReadOnlyList<AccessRow> SignedIn { get; private set; } = [];

	/// <summary>Access keys, most recently used first.</summary>
	public IReadOnlyList<AccessRow> Keys { get; private set; } = [];

	/// <summary>The Pebble plugin's access, read for watch faces.</summary>
	public IReadOnlyList<AccessRow> Watch { get; private set; } = [];

	/// <summary>What the plugin does, where an assistant's row says what it may do.</summary>
	public const string PluginLine = "Shows recording status on your watch faces";

	/// <summary>The plugin's Disconnect confirmation, after "Pebble plugin can't read your server after this."</summary>
	public const string PluginAfterwards = "Your watch faces stop showing your recording status.";

	/// <summary>Apps that registered or connected once but have no live connection.</summary>
	public IReadOnlyList<ConnectedApp> NotConnected { get; private set; } = [];

	public IReadOnlyList<EventSubscription> Subscriptions { get; private set; } = [];

	public DateTimeOffset Now => time.GetUtcNow();

	public TimeZoneInfo Zone { get; private set; } = TimeZoneInfo.Utc;

	public bool NoneConnected => SignedIn.Count == 0 && Keys.Count == 0;

	public async Task OnGetAsync(CancellationToken cancellationToken)
	{
		var userId = CurrentUserId();
		Zone = (await scopes.GetAsync(userId, cancellationToken)).TimeZone;
		var preferences = await requests.GetPreferencesAsync(userId, cancellationToken);
		var now = Now;
		var entries = await assistants.ListAsync(userId, cancellationToken);
		var rows = entries
			.Where(e => !PluginLinkService.IsPlugin(e))
			.Select(e => new AccessRow(
				e.Kind,
				e.Id,
				e.Name,
				SiteText.MayDo(preferences.Clips, preferences.Edits && SiteText.CanWrite(e.Scopes)),
				SiteText.LastRead(e.LastUsedAt, now, Zone)))
			.ToList();
		SignedIn = [.. rows.Where(r => r.Kind != TokenAssistantSource.KindName)];
		Keys = [.. rows.Where(r => r.Kind == TokenAssistantSource.KindName)];
		Watch = [.. entries
			.Where(PluginLinkService.IsPlugin)
			.Select(e => new AccessRow(e.Kind, e.Id, e.Name, PluginLine, SiteText.LastRead(e.LastUsedAt, now, Zone), PluginAfterwards))];
		NotConnected = [.. (await connections.ListAppsAsync(userId, cancellationToken)).Where(app => app.Connections.Count == 0)];
		Subscriptions = await subscriptions.ListAsync(userId, cancellationToken);
	}

	/// <summary>Ends one assistant's access at once: every connection of a signed-in app, or one access key.</summary>
	public async Task<IActionResult> OnPostDisconnectAsync(string kind, string id, CancellationToken cancellationToken)
	{
		await assistants.RevokeAsync(CurrentUserId(), kind, id, cancellationToken);
		return RedirectToPage();
	}

	public async Task<IActionResult> OnPostRemoveAsync(Guid id, CancellationToken cancellationToken)
	{
		await connections.RemoveAppAsync(CurrentUserId(), id, cancellationToken);
		return RedirectToPage();
	}

	public async Task<IActionResult> OnPostUnsubscribeAsync(string id, CancellationToken cancellationToken)
	{
		await subscriptions.RemoveAsync(CurrentUserId(), id, cancellationToken);
		return RedirectToPage();
	}

	/// <summary>"ChatGPT · Last sent 3 hr ago", or "Nothing sent yet".</summary>
	public string SubscriptionLine(EventSubscription subscription) =>
		$"{subscription.ClientName} · " + (subscription.LastDeliveredAt is { } sent
			? $"Last sent {SiteText.Ago(sent, Now, Zone)}"
			: "Nothing sent yet");

	public static string Host(string url) => Uri.TryCreate(url, UriKind.Absolute, out var uri) ? uri.Host : url;

	private Guid CurrentUserId() =>
		User.UserId() ?? throw new InvalidOperationException("Who can read requires a signed-in user.");
}

/// <param name="Kind">The access entry's kind, <c>oauth</c> or <c>token</c>, for Disconnect.</param>
/// <param name="Id">Its id within its kind.</param>
/// <param name="MayDo">"Can read and ask for clips".</param>
/// <param name="LastRead">"Last read 1 hr ago".</param>
/// <param name="Afterwards">What else disconnecting it changes, for the confirmation; an assistant's default when null.</param>
public sealed record AccessRow(string Kind, string Id, string Name, string MayDo, string LastRead, string? Afterwards = null);
