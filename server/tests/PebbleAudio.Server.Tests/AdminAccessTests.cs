using System.Net;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.DependencyInjection;
using PebbleAudio.Server.Auth;
using PebbleAudio.Server.Pages;
using PebbleAudio.Server.Pages.Admin;

namespace PebbleAudio.Server.Tests;

/// <summary>
/// Getting in: setup with the code and a passkey, signing in with that passkey alone, every page of the site behind it
/// in one layout, signing out, and the old admin addresses leading to their new pages.
/// </summary>
[Collection(ServerCollection.Name)]
public sealed partial class AdminAccessTests(ArchiveServerFactory factory)
{
	[Fact]
	public async Task Setup_takes_the_code_and_a_passkey_once_then_only_that_passkey_opens_the_site()
	{
		using var passkey = new SoftwarePasskey();
		var setupCode = factory.Services.GetRequiredService<SetupCodes>().Generated;
		using var browser = NewBrowser();

		// Signed out, the site sends you to sign in, and sign-in sends you to setup while none is done.
		var settings = await browser.GetAsync("/settings");
		Assert.Equal(HttpStatusCode.Redirect, settings.StatusCode);
		Assert.StartsWith("/sign-in", settings.Headers.Location!.PathAndQuery);
		var login = await browser.GetAsync("/sign-in");
		Assert.Equal("/setup", login.Headers.Location!.OriginalString);

		var csrf = await CsrfTokenAsync(browser, "/setup");

		// A wrong code gets no passkey options.
		var wrong = await browser.SendAsync(PasskeyPost("/setup", "PasskeyCreationOptions", csrf, setupCode: "AAAA-AAAA"));
		Assert.Equal(HttpStatusCode.Forbidden, wrong.StatusCode);

		// The right code, then the passkey: the account exists, is signed in, and goes on to link a phone.
		var options = await browser.SendAsync(PasskeyPost("/setup", "PasskeyCreationOptions", csrf, setupCode: setupCode.ToLowerInvariant()));
		Assert.Equal(HttpStatusCode.OK, options.StatusCode);
		var credential = passkey.Create(await options.Content.ReadAsStringAsync(), ArchiveServerFactory.PublicOrigin);
		var attested = await browser.SendAsync(PasskeyPost("/setup", "PasskeyAttestation", csrf, setupCode, credential));
		Assert.Equal(HttpStatusCode.OK, attested.StatusCode);
		Assert.Contains("/phones", await attested.Content.ReadAsStringAsync());

		// Every page of the site opens, each in the one layout with the site menu, Settings, and Sign Out.
		foreach (var path in new[] { "/settings", "/access", "/connect", "/connect/chatgpt", "/phones" })
		{
			var page = await browser.GetAsync(path);
			Assert.Equal(HttpStatusCode.OK, page.StatusCode);
			var html = await page.Content.ReadAsStringAsync();
			Assert.Contains("id=\"site-menu\"", html);
			Assert.Contains("href=\"/settings\"", html);
			Assert.Contains("Sign Out", html);
			Assert.DoesNotContain("/admin", html);
		}

		// Setup is closed for good.
		Assert.Equal(HttpStatusCode.NotFound, (await browser.GetAsync("/setup")).StatusCode);
		var signedInCsrf = await CsrfTokenAsync(browser, "/settings");
		var again = await browser.SendAsync(PasskeyPost("/setup", "PasskeyCreationOptions", signedInCsrf, setupCode));
		Assert.Equal(HttpStatusCode.NotFound, again.StatusCode);

		// Settings lists the passkey, and the only one can't be removed.
		Assert.Contains("This passkey signs you in here.", await browser.GetStringAsync("/settings"));
		var refused = await browser.PostAsync("/settings?handler=RemovePasskey&id=only", new FormUrlEncodedContent(new Dictionary<string, string>
		{
			["__RequestVerificationToken"] = signedInCsrf,
		}));
		Assert.Equal(HttpStatusCode.OK, refused.StatusCode);
		Assert.Contains("Add another passkey before removing this one.", await refused.Content.ReadAsStringAsync());

		// An access key made for another assistant opens /mcp. It is shown once, and Who can read lists it.
		var keyCsrf = await CsrfTokenAsync(browser, "/connect/other");
		var created = await browser.PostAsync("/connect/other?handler=Key", new FormUrlEncodedContent(new Dictionary<string, string>
		{
			["__RequestVerificationToken"] = keyCsrf,
			["Input.Name"] = "Codex on the test Mac",
		}));
		Assert.Equal(HttpStatusCode.OK, created.StatusCode);
		var secret = NewKeyPattern().Match(await created.Content.ReadAsStringAsync()).Groups[1].Value;
		Assert.StartsWith(ApiTokenService.Prefix, secret);
		using (var api = factory.CreateClient())
		{
			var listed = await api.SendAsync(McpTests.McpPost(secret));
			Assert.Equal(HttpStatusCode.OK, listed.StatusCode);
			Assert.Contains("get_status", await listed.Content.ReadAsStringAsync());
		}

		var access = WebUtility.HtmlDecode(await browser.GetStringAsync("/access"));
		Assert.Contains("Codex on the test Mac", access);
		Assert.Contains("Can read · Last read just now", access);
		Assert.DoesNotContain(secret, access);
		Assert.DoesNotContain(secret, await browser.GetStringAsync("/connect/other"));

		// A code shown at Link a phone links a phone, which then shows there.
		var phonesCsrf = await CsrfTokenAsync(browser, "/phones");
		var shown = await browser.PostAsync("/phones?handler=Link", new FormUrlEncodedContent(new Dictionary<string, string>
		{
			["__RequestVerificationToken"] = phonesCsrf,
		}));
		Assert.Equal(HttpStatusCode.OK, shown.StatusCode);
		var invitation = await shown.Content.ReadAsStringAsync();
		Assert.Contains("<svg", invitation);
		Assert.Contains($"{ArchiveServerFactory.PublicOrigin}/link?code=", invitation);
		var code = LinkCodePattern().Match(invitation).Groups[1].Value;
		Assert.Matches("^[A-Z0-9]{4}-[A-Z0-9]{4}$", code);
		using (var api = factory.CreateClient())
		{
			Assert.Equal(HttpStatusCode.Created, (await api.SendAsync(Phone.LinkRequest(code, "Admin test phone"))).StatusCode);
		}

		Assert.Contains("Admin test phone", await (await browser.GetAsync("/phones")).Content.ReadAsStringAsync());

		// A fresh browser signs in with the passkey alone.
		using var other = NewBrowser();
		var loginCsrf = await CsrfTokenAsync(other, "/sign-in");
		var requestOptions = await other.SendAsync(PasskeyPost("/sign-in", "PasskeyRequestOptions", loginCsrf));
		Assert.Equal(HttpStatusCode.OK, requestOptions.StatusCode);
		var assertion = passkey.Get(await requestOptions.Content.ReadAsStringAsync(), ArchiveServerFactory.PublicOrigin);
		var signedIn = await other.SendAsync(PasskeyPost("/sign-in", "PasskeySignIn", loginCsrf, body: assertion));
		Assert.Equal(HttpStatusCode.OK, signedIn.StatusCode);
		Assert.Equal(HttpStatusCode.OK, (await other.GetAsync("/settings")).StatusCode);

		// The Sign Out button's own form (with the token the page put in it) closes the site again.
		var settingsPage = await (await other.GetAsync("/settings")).Content.ReadAsStringAsync();
		var signOut = SignOutFormPattern().Match(settingsPage);
		Assert.True(signOut.Success, "The layout's sign-out form carries no antiforgery token.");
		var signedOut = await other.PostAsync(
			signOut.Groups["action"].Value,
			new FormUrlEncodedContent(new Dictionary<string, string> { ["__RequestVerificationToken"] = signOut.Groups["token"].Value }));
		Assert.Equal(HttpStatusCode.Redirect, signedOut.StatusCode);
		Assert.Equal("/sign-in", signedOut.Headers.Location!.OriginalString);
		Assert.Equal(HttpStatusCode.Redirect, (await other.GetAsync("/settings")).StatusCode);
	}

	[Fact]
	public async Task The_old_admin_addresses_lead_to_their_new_pages_with_the_query_and_the_method_kept()
	{
		using var browser = NewBrowser();
		foreach (var (from, to) in OldAdminUrls.Moves)
		{
			var moved = await browser.GetAsync(from);
			Assert.Equal(HttpStatusCode.TemporaryRedirect, moved.StatusCode);
			Assert.Equal(to, moved.Headers.Location!.OriginalString);
		}

		// The sign-in an app's OAuth flow started keeps its way back; a saved notice keeps its place on the page.
		var login = await browser.GetAsync("/admin/login?ReturnUrl=%2Foauth%2Fauthorize%3Fclient_id%3Dx");
		Assert.Equal("/sign-in?ReturnUrl=%2Foauth%2Fauthorize%3Fclient_id%3Dx", login.Headers.Location!.OriginalString);
		var saved = await browser.GetAsync("/admin/settings?saved=true");
		Assert.Equal("/settings?saved=true#limits", saved.Headers.Location!.OriginalString);

		// An old tab's form goes on to the same handler on the new page, still a POST.
		var posted = await browser.PostAsync("/admin/apps?handler=Disconnect&kind=oauth&id=x", new FormUrlEncodedContent([]));
		Assert.Equal(HttpStatusCode.TemporaryRedirect, posted.StatusCode);
		Assert.Equal("/access?handler=Disconnect&kind=oauth&id=x", posted.Headers.Location!.OriginalString);

		// Where they lead is still behind the passkey.
		var signedOut = await browser.GetAsync("/access");
		Assert.Equal(HttpStatusCode.Redirect, signedOut.StatusCode);
		Assert.StartsWith("/sign-in?ReturnUrl=%2Faccess", signedOut.Headers.Location!.PathAndQuery);
	}

	private HttpClient NewBrowser() =>
		factory.CreateClient(new WebApplicationFactoryClientOptions { AllowAutoRedirect = false, HandleCookies = true });

	private static async Task<string> CsrfTokenAsync(HttpClient browser, string path)
	{
		var page = await browser.GetAsync(path);
		Assert.Equal(HttpStatusCode.OK, page.StatusCode);
		return CsrfPattern().Match(await page.Content.ReadAsStringAsync()).Groups[1].Value;
	}

	private static HttpRequestMessage PasskeyPost(string path, string handler, string csrf, string? setupCode = null, string? body = null)
	{
		var request = new HttpRequestMessage(HttpMethod.Post, $"{path}?handler={handler}");
		request.Headers.Add("RequestVerificationToken", csrf);
		request.Headers.Add("Origin", ArchiveServerFactory.PublicOrigin);
		if (setupCode is not null)
		{
			request.Headers.Add(SetupModel.SetupCodeHeader, setupCode);
		}

		if (body is not null)
		{
			request.Content = new StringContent(body, Encoding.UTF8, "application/json");
		}

		return request;
	}

	[GeneratedRegex("<meta name=\"csrf-token\" content=\"([^\"]+)\"")]
	private static partial Regex CsrfPattern();

	[GeneratedRegex("<pre class=\"cmd flat\" id=\"cmd\"><span class=\"k\">(pat_[^<]+)</span></pre>")]
	private static partial Regex NewKeyPattern();

	[GeneratedRegex("<div class=\"code-boxes\" data-code=\"([^\"]+)\"")]
	private static partial Regex LinkCodePattern();

	[GeneratedRegex("<form method=\"post\" class=\"signout\" action=\"(?<action>[^\"]+)\">\\s*<button[^>]*>[^<]*</button>\\s*<input name=\"__RequestVerificationToken\" type=\"hidden\" value=\"(?<token>[^\"]+)\"")]
	private static partial Regex SignOutFormPattern();
}
