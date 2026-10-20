using Microsoft.AspNetCore.Identity;

namespace PebbleAudio.Server.Auth;

/// <summary>
/// The person who owns the archive. There is one for now; every archive row carries its id.
/// </summary>
public sealed class ApplicationUser : IdentityUser<Guid>
{
	public DateTimeOffset CreatedAt { get; set; }
}
