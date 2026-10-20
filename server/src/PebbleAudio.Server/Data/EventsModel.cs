using Microsoft.EntityFrameworkCore;
using PebbleAudio.Server.Auth;

namespace PebbleAudio.Server.Data;

/// <summary>
/// The MCP Events tables (see <c>Events/</c>), kept apart from the rest of the model.
/// </summary>
internal static class EventsModel
{
	public static void Configure(ModelBuilder builder)
	{
		builder.Entity<EventSubscription>(entity =>
		{
			entity.Property(s => s.Id).HasMaxLength(40);
			entity.HasIndex(s => new { s.UserId, s.EventName });
			entity.HasOne<ApplicationUser>().WithMany().HasForeignKey(s => s.UserId).OnDelete(DeleteBehavior.Cascade);
			entity.HasOne<OAuthGrant>().WithMany().HasForeignKey(s => s.GrantId).OnDelete(DeleteBehavior.Cascade);
			entity.HasOne<ApiToken>().WithMany().HasForeignKey(s => s.ApiTokenId).OnDelete(DeleteBehavior.Cascade);
		});
	}
}
