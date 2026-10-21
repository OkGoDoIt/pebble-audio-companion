using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;
using PebbleAudio.Server.Auth;

namespace PebbleAudio.Server.Pages.OAuth;

/// <summary>
/// <c>/oauth/authorize</c>: checks the request, sends a signed-out person through the passkey sign-in and back, and
/// asks them to allow or deny the app. The form posts to the same URL, so the request is checked again on the way
/// out and nothing the page shows can be swapped in transit.
/// </summary>
public sealed class AuthorizeModel(
	OAuthAuthorization authorization,
	OAuthClientResolver clients,
	OAuthTokenService tokens,
	ILogger<AuthorizeModel> logger)
	: PageModel
{
	/// <summary>Set when the request cannot be answered with a redirect.</summary>
	public string? Problem { get; private set; }

	public AuthorizationRequest? Pending { get; private set; }

	public string AppName => Pending is { } p ? OAuthClientNames.Display(p.Client.Name, p.RedirectUri) : "";

	/// <summary>Where the app's identity comes from: the host serving its metadata document, or null when it registered itself.</summary>
	public string? VerifiedHost => Pending?.Client.MetadataHost;

	public bool ReturnsToThisDevice => Pending is { } p && OAuthRedirects.IsLoopback(p.RedirectUri);

	public string ReturnHost => Pending is { } p ? OAuthRedirects.Host(p.RedirectUri) : "";

	public IReadOnlyList<string> Abilities =>
		Pending is { } p ? [.. p.Scopes.Select(ArchiveScopes.Explain).OfType<string>()] : [];

	public async Task<IActionResult> OnGetAsync(CancellationToken cancellationToken)
	{
		if (await SignInFirstAsync(cancellationToken))
		{
			return Challenge();
		}

		var check = await authorization.CheckAsync(Request.Query, cancellationToken);
		if (Answer(check) is { } answer)
		{
			return answer;
		}

		return User.UserId() is null ? Challenge() : Page();
	}

	public async Task<IActionResult> OnPostAsync(string? decision, CancellationToken cancellationToken)
	{
		if (await SignInFirstAsync(cancellationToken))
		{
			return Challenge();
		}

		var check = await authorization.CheckAsync(Request.Query, cancellationToken);
		if (Answer(check) is { } answer)
		{
			return answer;
		}

		if (User.UserId() is not { } userId)
		{
			return Challenge();
		}

		var request = Pending!;
		if (decision != "allow")
		{
			logger.LogInformation("Sign-in for {App} was denied.", AppName);
			return Redirect(authorization.ErrorLocation(request.RedirectUri, "access_denied", "the person did not allow access", request.State));
		}

		var clientRowId = await clients.SaveAsync(request.Client, cancellationToken);
		var code = await tokens.IssueCodeAsync(clientRowId, userId, request, cancellationToken);
		logger.LogInformation("Sign-in for {App} was allowed with {Scopes}.", AppName, string.Join(' ', request.Scopes));
		return Redirect(authorization.SuccessLocation(request, code));
	}

	/// <summary>
	/// Signed out, an app whose metadata document this server has never seen waits for the sign-in before its URL is
	/// fetched; the person comes back to the same request.
	/// </summary>
	private async Task<bool> SignInFirstAsync(CancellationToken cancellationToken) =>
		User.UserId() is null &&
		Request.Query.TryGetValue("client_id", out var clientId) &&
		clientId.Count == 1 &&
		await clients.IsUnseenDocumentAsync(clientId[0], cancellationToken);

	/// <summary>The response for a request that cannot go on to consent, or null (and <see cref="Pending"/> set) when it can.</summary>
	private IActionResult? Answer(AuthorizeCheck check)
	{
		// The consent page is never shown inside another site's frame, where its Allow button could be clicked blind.
		Response.Headers.XFrameOptions = "DENY";
		Response.Headers.ContentSecurityPolicy = "frame-ancestors 'none'";

		switch (check)
		{
			case AuthorizeCheck.Rejected rejected:
				Problem = rejected.Problem;
				Response.StatusCode = StatusCodes.Status400BadRequest;
				return Page();
			case AuthorizeCheck.Failed failed:
				return Redirect(failed.Location);
			case AuthorizeCheck.Accepted accepted:
				Pending = accepted.Request;
				return null;
			default:
				throw new InvalidOperationException($"Unhandled authorization check {check.GetType().Name}.");
		}
	}
}
