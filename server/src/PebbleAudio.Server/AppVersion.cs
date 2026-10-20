using System.Reflection;

namespace PebbleAudio.Server;

/// <summary>
/// The running build: the project version plus the git commit the SDK stamps into the informational version.
/// </summary>
public static class AppVersion
{
	private static readonly string Informational =
		typeof(AppVersion).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion
		?? "0.0.0";

	/// <summary>
	/// The version number, for example <c>0.1.0</c>.
	/// </summary>
	public static string Number { get; } = Informational.Split('+')[0];

	/// <summary>
	/// The short commit hash, when the build knew it.
	/// </summary>
	public static string? Commit { get; } =
		Informational.Split('+') is [_, var revision, ..] && revision.Length >= 7 ? revision[..7] : null;

	/// <summary>
	/// The version and commit, for example <c>0.1.0+1a2b3c4</c>.
	/// </summary>
	public static string Display { get; } = Commit is null ? Number : $"{Number}+{Commit}";
}
