using Microsoft.AspNetCore.Mvc;

namespace PebbleAudio.Server.Pages.Admin;

/// <summary>
/// The plumbing the passkey pages share: reading the browser's credential JSON and answering with JSON errors
/// that passkeys.js shows as the status line.
/// </summary>
internal static class PasskeyRequests
{
	public static async Task<string?> ReadBodyAsync(HttpRequest request, CancellationToken cancellationToken)
	{
		using var reader = new StreamReader(request.Body);
		var body = await reader.ReadToEndAsync(cancellationToken);
		return string.IsNullOrWhiteSpace(body) ? null : body;
	}

	public static JsonResult Error(int statusCode, string message) =>
		new(new { error = message }) { StatusCode = statusCode };

	public static JsonResult Done(string returnUrl) => new(new { ok = true, returnUrl });
}
