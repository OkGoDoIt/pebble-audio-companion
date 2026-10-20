using Microsoft.EntityFrameworkCore;

namespace PebbleAudio.Server.Data;

// The OAuth and MCP Events tables; their configuration is in OAuthModel and EventsModel.
public sealed partial class ArchiveDbContext
{
	public DbSet<OAuthClient> OAuthClients => Set<OAuthClient>();

	public DbSet<OAuthGrant> OAuthGrants => Set<OAuthGrant>();

	public DbSet<OAuthToken> OAuthTokens => Set<OAuthToken>();

	public DbSet<OAuthAuthorizationCode> OAuthAuthorizationCodes => Set<OAuthAuthorizationCode>();

	public DbSet<EventSubscription> EventSubscriptions => Set<EventSubscription>();
}
