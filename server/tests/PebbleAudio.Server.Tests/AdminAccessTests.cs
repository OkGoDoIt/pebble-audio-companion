using System.Net;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.DependencyInjection;
using PebbleAudio.Server.Auth;
using PebbleAudio.Server.Pages.Admin;

namespace PebbleAudio.Server.Tests;

[Collection(ServerCollection.Name)]
public sealed partial class AdminAccessTests(ArchiveServerFactory factory)
{
	[Fact]
	public async Task Setup_takes_the_code_and_a_passkey_once_then_only_that_passkey_opens_the_admin_area()
	{
		using var passkey = new SoftwarePasskey();
		var setupCode = factory.Services.GetRequiredService<SetupCodes>().Generated;
		using var browser = NewBrowser();

		// Signed out, the admin area sends you to sign in, and sign-in sends you to setup while none is done.
		var admin = await browser.GetAsync("/admin");
		Assert.Equal(HttpStatusCode.Redirect, admin.StatusCode);
		Assert.StartsWith("/admin/login", admin.Headers.Location!.PathAndQuery);
		var login = await browser.GetAsync("/admin/login");
		Assert.Equal("/admin/setup", login.Headers.Location!.OriginalString);

		var csrf = await CsrfTokenAsync(browser, "/admin/setup");

		// A wrong code gets no passkey options.
		var wrong = await browser.SendAsync(PasskeyPost("/admin/setup", "PasskeyCreationOptions", csrf, setupCode: "AAAA-AAAA"));
		Assert.Equal(HttpStatusCode.Forbidden, wrong.StatusCode);

		// The right code, then the passkey: the admin user exists and is signed in.
		var options = await browser.SendAsync(PasskeyPost("/admin/setup", "PasskeyCreationOptions", csrf, setupCode: setupCode.ToLowerInvariant()));
		Assert.Equal(HttpStatusCode.OK, options.StatusCode);
		var credential = passkey.Create(await options.Content.ReadAsStringAsync(), ArchiveServerFactory.PublicOrigin);
		var attested = await browser.SendAsync(PasskeyPost("/admin/setup", "PasskeyAttestation", csrf, setupCode, credential));
		Assert.Equal(HttpStatusCode.OK, attested.StatusCode);

		Assert.Equal(HttpStatusCode.OK, (await browser.GetAsync("/admin")).StatusCode);
		Assert.Equal(HttpStatusCode.OK, (await browser.GetAsync("/admin/passkeys")).StatusCode);
		Assert.Equal(HttpStatusCode.OK, (await browser.GetAsync("/admin/settings")).StatusCode);

		// Setup is closed for good.
		Assert.Equal(HttpStatusCode.NotFound, (await browser.GetAsync("/admin/setup")).StatusCode);
		var signedInCsrf = await CsrfTokenAsync(browser, "/admin");
		var again = await browser.SendAsync(PasskeyPost("/admin/setup", "PasskeyCreationOptions", signedInCsrf, setupCode));
		Assert.Equal(HttpStatusCode.NotFound, again.StatusCode);

		// A token made in the admin area opens /mcp.
		var tokensPage = await CsrfTokenAsync(browser, "/admin/tokens");
		var created = await browser.PostAsync("/admin/tokens?handler=Create", new FormUrlEncodedContent(new Dictionary<string, string>
		{
			["__RequestVerificationToken"] = tokensPage,
			["Input.Name"] = "Codex on the test Mac",
			["Input.Access"] = "Read",
		}));
		Assert.Equal(HttpStatusCode.OK, created.StatusCode);
		var secret = NewTokenPattern().Match(await created.Content.ReadAsStringAsync()).Groups[1].Value;
		Assert.StartsWith(ApiTokenService.Prefix, secret);
		using (var api = factory.CreateClient())
		{
			var listed = await api.SendAsync(McpTests.McpPost(secret));
			Assert.Equal(HttpStatusCode.OK, listed.StatusCode);
			Assert.Contains("get_status", await listed.Content.ReadAsStringAsync());
		}

		// A fresh browser signs in with the passkey alone.
		using var other = NewBrowser();
		var loginCsrf = await CsrfTokenAsync(other, "/admin/login");
		var requestOptions = await other.SendAsync(PasskeyPost("/admin/login", "PasskeyRequestOptions", loginCsrf));
		Assert.Equal(HttpStatusCode.OK, requestOptions.StatusCode);
		var assertion = passkey.Get(await requestOptions.Content.ReadAsStringAsync(), ArchiveServerFactory.PublicOrigin);
		var signedIn = await other.SendAsync(PasskeyPost("/admin/login", "PasskeySignIn", loginCsrf, body: assertion));
		Assert.Equal(HttpStatusCode.OK, signedIn.StatusCode);
		Assert.Equal(HttpStatusCode.OK, (await other.GetAsync("/admin")).StatusCode);

		// The sign-out button's own form (with the token the page put in it) closes the admin area again.
		var page = await (await other.GetAsync("/admin")).Content.ReadAsStringAsync();
		var signOut = SignOutFormPattern().Match(page);
		Assert.True(signOut.Success, "The layout's sign-out form carries no antiforgery token.");
		var signedOut = await other.PostAsync(
			signOut.Groups["action"].Value,
			new FormUrlEncodedContent(new Dictionary<string, string> { ["__RequestVerificationToken"] = signOut.Groups["token"].Value }));
		Assert.Equal(HttpStatusCode.Redirect, signedOut.StatusCode);
		Assert.Equal(HttpStatusCode.Redirect, (await other.GetAsync("/admin")).StatusCode);
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

	[GeneratedRegex("<code id=\"new-token\">(pat_[^<]+)</code>")]
	private static partial Regex NewTokenPattern();

	[GeneratedRegex("<form method=\"post\" class=\"signout\" action=\"(?<action>[^\"]+)\">\\s*<button[^>]*>[^<]*</button>\\s*<input name=\"__RequestVerificationToken\" type=\"hidden\" value=\"(?<token>[^\"]+)\"")]
	private static partial Regex SignOutFormPattern();
}
