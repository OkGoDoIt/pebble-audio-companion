using Microsoft.EntityFrameworkCore;
using PebbleAudio.Server.Data;
using PebbleAudio.Server.Sync;

namespace PebbleAudio.Server.Auth;

/// <summary>
/// An OAuth app as the admin area lists it, with the user's live connections to it.
/// </summary>
public sealed record ConnectedApp(
	Guid Id,
	string Name,
	OAuthClientKind Kind,
	string? MetadataHost,
	DateTimeOffset CreatedAt,
	IReadOnlyList<AppConnection> Connections)
{
	/// <summary>Where the app is from: its metadata document's host, or for a self-registered app, where it returns to.</summary>
	public string? Host { get; init; }
}

/// <summary>
/// One live grant: the app can read (and maybe write) until it is disconnected or goes unused past its sign-in
/// lifetime.
/// </summary>
public sealed record AppConnection(
	Guid GrantId,
	string RedirectHost,
	bool IsLoopback,
	IReadOnlyList<string> Scopes,
	DateTimeOffset ConnectedAt,
	DateTimeOffset? LastUsedAt);

/// <summary>
/// The user's OAuth connections: listed for the admin area and the phone (<c>access</c> in <c>GET /sync/status</c>),
/// and disconnected from either. Disconnecting deletes the grant, which ends its tokens and its event subscriptions.
/// </summary>
public sealed class OAuthConnections(ArchiveDbContext db, TimeProvider time) : IConnectedAssistantSource
{
	public const string Kind = "oauth";

	/// <summary>
	/// Every app, newest first, with this user's live connections; apps with none are listed too, so the admin can
	/// remove them.
	/// </summary>
	public async Task<IReadOnlyList<ConnectedApp>> ListAppsAsync(Guid userId, CancellationToken cancellationToken)
	{
		var now = time.GetUtcNow();
		var clients = await db.OAuthClients.AsNoTracking()
			.OrderByDescending(c => c.CreatedAt)
			.Select(c => new
			{
				Client = c,
				Grants = c.Grants
					.Where(g => g.UserId == userId && g.ExpiresAt > now)
					.OrderByDescending(g => g.CreatedAt)
					.ToList(),
			})
			.ToListAsync(cancellationToken);

		return
		[
			.. clients.Select(row => new ConnectedApp(
				row.Client.Id,
				OAuthClientNames.Display(row.Client.Name, row.Grants.FirstOrDefault()?.RedirectUri ?? row.Client.RedirectUris.FirstOrDefault()),
				row.Client.Kind,
				row.Client.Kind == OAuthClientKind.MetadataDocument ? new Uri(row.Client.ClientId).Host : null,
				row.Client.CreatedAt,
				[
					.. row.Grants.Select(g => new AppConnection(
						g.Id,
						OAuthRedirects.Host(g.RedirectUri),
						OAuthRedirects.IsLoopback(g.RedirectUri),
						ArchiveScopesOf(g.Scopes),
						g.CreatedAt,
						g.LastUsedAt)),
				])
			{
				Host = row.Client.Kind == OAuthClientKind.MetadataDocument
					? new Uri(row.Client.ClientId).Host
					: row.Client.RedirectUris.Select(OAuthRedirects.Host).FirstOrDefault(),
			}),
		];
	}

	/// <summary>One <c>access</c> entry per app with at least one live connection.</summary>
	public async Task<IReadOnlyList<ConnectedAssistant>> ListAsync(Guid userId, CancellationToken cancellationToken)
	{
		var apps = await ListAppsAsync(userId, cancellationToken);
		return
		[
			.. apps.Where(a => a.Connections.Count > 0).Select(a => new ConnectedAssistant(
				Kind,
				a.Id.ToString(),
				a.Name,
				[.. a.Connections.SelectMany(c => c.Scopes).Distinct().Order(StringComparer.Ordinal)],
				a.Connections.Min(c => c.ConnectedAt),
				a.Connections.Max(c => c.LastUsedAt))),
		];
	}

	/// <summary>Disconnects every connection the user has to one app (its <c>access</c> id is the app's id).</summary>
	public async Task<bool> RevokeAsync(Guid userId, string kind, string id, CancellationToken cancellationToken)
	{
		if (kind != Kind || !Guid.TryParse(id, out var clientRowId))
		{
			return false;
		}

		var deleted = await db.OAuthGrants
			.Where(g => g.UserId == userId && g.OAuthClientId == clientRowId)
			.ExecuteDeleteAsync(cancellationToken);
		return deleted > 0;
	}

	/// <summary>Disconnects one connection.</summary>
	public async Task<bool> DisconnectAsync(Guid userId, Guid grantId, CancellationToken cancellationToken) =>
		await db.OAuthGrants.Where(g => g.Id == grantId && g.UserId == userId).ExecuteDeleteAsync(cancellationToken) > 0;

	/// <summary>
	/// Forgets an app with no live connections for this user. A registered app has to register again; a
	/// metadata-document app gets a new row the next time it is allowed.
	/// </summary>
	public async Task<bool> RemoveAppAsync(Guid userId, Guid clientRowId, CancellationToken cancellationToken)
	{
		var now = time.GetUtcNow();
		var deleted = await db.OAuthClients
			.Where(c => c.Id == clientRowId && !c.Grants.Any(g => g.UserId == userId && g.ExpiresAt > now))
			.ExecuteDeleteAsync(cancellationToken);
		return deleted > 0;
	}

	/// <summary>The scopes people care about; <c>offline_access</c> says nothing about what the app can do.</summary>
	private static List<string> ArchiveScopesOf(List<string> scopes) =>
		[.. scopes.Where(s => s is ArchiveScopes.Read or ArchiveScopes.Write)];
}
