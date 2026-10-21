namespace PebbleAudio.Server.Pages;

/// <summary>
/// The admin area's old addresses, which now live in the site's own pages: each answers 307 to where its page went,
/// with the query kept, so a bookmark, an open tab's form, or an old link still lands in the right place.
/// </summary>
public static class OldAdminUrls
{
	/// <summary>Old path, and where it went (a section of a page keeps its fragment).</summary>
	public static IReadOnlyList<(string From, string To)> Moves { get; } =
	[
		("/admin", "/settings"),
		("/admin/index", "/settings"),
		("/admin/apps", "/access"),
		("/admin/tokens", "/access#keys"),
		("/admin/phones", "/phones"),
		("/admin/passkeys", "/settings#passkeys"),
		("/admin/settings", "/settings#limits"),
		("/admin/login", "/sign-in"),
		("/admin/setup", "/setup"),
		("/admin/logout", "/sign-out"),
	];

	public static IEndpointRouteBuilder MapOldAdminUrls(this IEndpointRouteBuilder app)
	{
		foreach (var (from, to) in Moves)
		{
			app.MapMethods(from, [HttpMethods.Get, HttpMethods.Head, HttpMethods.Post], (HttpContext context) =>
				Results.Redirect(Target(to, context.Request.QueryString), permanent: false, preserveMethod: true))
				.AllowAnonymous()
				.DisableAntiforgery()
				.ExcludeFromDescription();
		}

		return app;
	}

	/// <summary>The new address with the request's query, which goes before any fragment.</summary>
	public static string Target(string to, QueryString query)
	{
		var hash = to.IndexOf('#', StringComparison.Ordinal);
		return hash < 0 ? to + query : to[..hash] + query + to[hash..];
	}
}
