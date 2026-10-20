using Microsoft.EntityFrameworkCore;
using PebbleAudio.Server.Auth;

namespace PebbleAudio.Server.Data;

/// <summary>
/// The OAuth authorization server's tables (see <c>Auth/</c>), kept apart from the rest of the model so the module's
/// schema changes stay in one place.
/// </summary>
internal static class OAuthModel
{
	public static void Configure(ModelBuilder builder)
	{
		builder.Entity<OAuthClient>(entity =>
		{
			entity.HasIndex(c => c.ClientId).IsUnique();
			entity.Property(c => c.ClientId).HasMaxLength(2048);
			entity.Property(c => c.Name).HasMaxLength(200);
		});

		builder.Entity<OAuthGrant>(entity =>
		{
			entity.HasIndex(g => new { g.UserId, g.OAuthClientId });
			entity.HasOne(g => g.Client).WithMany(c => c.Grants).HasForeignKey(g => g.OAuthClientId).OnDelete(DeleteBehavior.Cascade);
			entity.HasOne<ApplicationUser>().WithMany().HasForeignKey(g => g.UserId).OnDelete(DeleteBehavior.Cascade);
		});

		builder.Entity<OAuthToken>(entity =>
		{
			entity.HasIndex(t => t.TokenHash).IsUnique();
			entity.HasIndex(t => new { t.GrantId, t.Kind });
			entity.HasIndex(t => t.ExpiresAt);
			entity.HasOne(t => t.Grant).WithMany(g => g.Tokens).HasForeignKey(t => t.GrantId).OnDelete(DeleteBehavior.Cascade);
		});

		builder.Entity<OAuthAuthorizationCode>(entity =>
		{
			entity.HasIndex(c => c.CodeHash).IsUnique();
			entity.HasIndex(c => c.ExpiresAt);
			entity.HasOne<OAuthClient>().WithMany().HasForeignKey(c => c.OAuthClientId).OnDelete(DeleteBehavior.Cascade);
			entity.HasOne<ApplicationUser>().WithMany().HasForeignKey(c => c.UserId).OnDelete(DeleteBehavior.Cascade);
			entity.HasOne<OAuthGrant>().WithMany().HasForeignKey(c => c.GrantId).OnDelete(DeleteBehavior.SetNull);
		});
	}
}
