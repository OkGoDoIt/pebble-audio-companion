using System.Globalization;

namespace PebbleAudio.Server.Pages;

/// <summary>
/// Numbers as the server's pages show them. Times are written on the server in the account's time zone, in the
/// phone's words (<see cref="SiteText"/>).
/// </summary>
public static class Display
{
	public static string Count(int value) => value.ToString("N0", CultureInfo.InvariantCulture);
}
