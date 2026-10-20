using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;
using PebbleAudio.Server.Auth;
using PebbleAudio.Server.Data;
using PebbleAudio.Server.Events;

namespace PebbleAudio.Server.Pages.Admin;

public sealed class AppsModel(OAuthConnections connections, EventSubscriptions subscriptions, OAuthUrls urls) : PageModel
{
	/// <summary>One row per live connection, newest app first.</summary>
	public IReadOnlyList<(ConnectedApp App, AppConnection Connection)> Connected { get; private set; } = [];

	/// <summary>Apps that registered or connected once but have no live connection.</summary>
	public IReadOnlyList<ConnectedApp> NotConnected { get; private set; } = [];

	public IReadOnlyList<EventSubscription> Subscriptions { get; private set; } = [];

	public string McpUrl => urls.Resource;

	public async Task OnGetAsync(CancellationToken cancellationToken)
	{
		var userId = CurrentUserId();
		var apps = await connections.ListAppsAsync(userId, cancellationToken);
		Connected = [.. apps.SelectMany(app => app.Connections.Select(connection => (app, connection)))];
		NotConnected = [.. apps.Where(app => app.Connections.Count == 0)];
		Subscriptions = await subscriptions.ListAsync(userId, cancellationToken);
	}

	public async Task<IActionResult> OnPostDisconnectAsync(Guid id, CancellationToken cancellationToken)
	{
		await connections.DisconnectAsync(CurrentUserId(), id, cancellationToken);
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

	public static string Place(AppConnection connection) => connection.IsLoopback ? "This device" : connection.RedirectHost;

	public static string Host(string url) => Uri.TryCreate(url, UriKind.Absolute, out var uri) ? uri.Host : url;

	private Guid CurrentUserId() =>
		User.UserId() ?? throw new InvalidOperationException("The admin page requires a signed-in user.");
}
