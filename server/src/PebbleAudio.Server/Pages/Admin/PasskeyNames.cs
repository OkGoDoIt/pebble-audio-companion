namespace PebbleAudio.Server.Pages.Admin;

internal static class PasskeyNames
{
	public const int MaxLength = 60;

	/// <summary>
	/// The name the person typed, or the kind of device the passkey was made on.
	/// </summary>
	public static string Choose(string? typed, string? userAgent)
	{
		var name = typed?.Trim();
		if (!string.IsNullOrEmpty(name))
		{
			return name.Length > MaxLength ? name[..MaxLength] : name;
		}

		return FromDevice(userAgent);
	}

	/// <summary>
	/// A plain device name from the browser's user agent, for example "iPhone" or "Mac".
	/// </summary>
	public static string FromDevice(string? userAgent)
	{
		var agent = userAgent ?? "";
		string[][] devices =
		[
			["iPhone", "iPhone"],
			["iPad", "iPad"],
			["Android", "Android phone"],
			["Macintosh", "Mac"],
			["Windows", "Windows PC"],
			["CrOS", "Chromebook"],
			["Linux", "Linux PC"],
		];
		foreach (var device in devices)
		{
			if (agent.Contains(device[0], StringComparison.Ordinal))
			{
				return device[1];
			}
		}

		return "Passkey";
	}
}
