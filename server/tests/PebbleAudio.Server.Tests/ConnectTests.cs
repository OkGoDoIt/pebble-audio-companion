using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.DependencyInjection;
using PebbleAudio.Server.Auth;

namespace PebbleAudio.Server.Tests;

/// <summary>
/// Connecting a Mac app at /connect/{tool} (OAuth first, an access key only as the fallback, shown once) and the
/// /link page a phone without the app opens from the QR code.
/// </summary>
[Collection(ServerCollection.Name)]
public sealed partial class ConnectTests(ArchiveServerFactory factory)
{
	[Fact]
	public async Task Connecting_codex_signs_in_first_and_its_fallback_key_shows_once_and_turns_the_wait_into_a_check()
	{
		using var anonymous = factory.CreateClient(new WebApplicationFactoryClientOptions { AllowAutoRedirect = false });
		var redirect = await anonymous.GetAsync("/connect/codex");
		Assert.Equal(HttpStatusCode.Redirect, redirect.StatusCode);
		Assert.Contains("/admin/login", redirect.Headers.Location!.ToString(), StringComparison.Ordinal);

		var userId = await factory.CreateUserAsync();
		using var browser = factory.CreateClient(new WebApplicationFactoryClientOptions { AllowAutoRedirect = false });
		Assert.Equal(HttpStatusCode.OK, (await browser.GetAsync($"{TestSignIn.Path}?userId={userId}")).StatusCode);
		Assert.Equal(HttpStatusCode.NotFound, (await browser.GetAsync("/connect/notepad")).StatusCode);

		// The default path is OAuth: no key on the page.
		var page = WebUtility.HtmlDecode(await browser.GetStringAsync("/connect/codex"));
		Assert.Contains($"codex mcp add pebble-audio --url {ArchiveServerFactory.PublicOrigin}/mcp", page, StringComparison.Ordinal);
		Assert.Contains("codex mcp login pebble-audio", page, StringComparison.Ordinal);
		Assert.DoesNotContain(ApiTokenService.Prefix, page, StringComparison.Ordinal);
		var since = Since().Match(page).Groups["ms"].Value;
		Assert.Contains("data-ready=\"false\"", page, StringComparison.Ordinal);

		// Cursor's button installs the server's URL.
		var cursor = WebUtility.HtmlDecode(await browser.GetStringAsync("/connect/cursor"));
		var config = CursorConfig().Match(cursor).Groups["config"].Value;
		Assert.Equal($$"""{"url":"{{ArchiveServerFactory.PublicOrigin}}/mcp"}""", Encoding.UTF8.GetString(Convert.FromBase64String(Uri.UnescapeDataString(config))));

		// The fallback mints a key named for the app and shows it in that response only.
		var csrf = Csrf().Match(page).Groups["token"].Value;
		var minted = await browser.PostAsync("/connect/codex?handler=Key", new FormUrlEncodedContent(new Dictionary<string, string> { ["__RequestVerificationToken"] = csrf }));
		Assert.Equal(HttpStatusCode.OK, minted.StatusCode);
		// As text: the key is highlighted inside the command.
		var withKey = WebUtility.HtmlDecode(Regex.Replace(await minted.Content.ReadAsStringAsync(), "<span class=\"k\">|</span>", ""));
		var key = Key().Match(withKey).Value;
		Assert.StartsWith(ApiTokenService.Prefix, key);
		Assert.Contains($"echo 'export PEBBLE_AUDIO_KEY={key}' >> ~/.zshrc", withKey, StringComparison.Ordinal);
		Assert.Contains("bearer_token_env_var = \"PEBBLE_AUDIO_KEY\"", withKey, StringComparison.Ordinal);
		await using (var scope = factory.Services.CreateAsyncScope())
		{
			var listed = await scope.ServiceProvider.GetRequiredService<ApiTokenService>().ListAsync(userId, CancellationToken.None);
			Assert.Equal("Codex on Mac", Assert.Single(listed).Name);
		}

		Assert.DoesNotContain(key, await browser.GetStringAsync("/connect/codex"), StringComparison.Ordinal);

		// Codex waits until it reads with its key; then the list says it is connected.
		var waiting = await browser.GetStringAsync($"/connect/codex?handler=Who&since={since}");
		Assert.Contains("data-ready=\"false\"", waiting, StringComparison.Ordinal);
		Assert.Contains("Waiting for it to read", waiting, StringComparison.Ordinal);
		using (var codex = factory.CreateClient())
		{
			Assert.Equal(HttpStatusCode.OK, (await codex.SendAsync(McpTests.McpPost(key))).StatusCode);
		}

		var arrived = await browser.GetStringAsync($"/connect/codex?handler=Who&since={since}");
		Assert.Contains("data-ready=\"true\"", arrived, StringComparison.Ordinal);
		Assert.Contains("Codex on Mac", arrived, StringComparison.Ordinal);
	}

	[Fact]
	public async Task The_link_page_shows_the_code_to_type_without_signing_in()
	{
		using var phone = factory.CreateClient(new WebApplicationFactoryClientOptions { AllowAutoRedirect = false });

		var response = await phone.GetAsync("/link?code=k7qm3xwd");

		Assert.Equal(HttpStatusCode.OK, response.StatusCode);
		var page = await response.Content.ReadAsStringAsync();
		Assert.Contains("K7QM-3XWD", page, StringComparison.Ordinal);
		Assert.Contains("Pebble Audio", page, StringComparison.Ordinal);
		Assert.DoesNotContain("Signed in with your passkey", page, StringComparison.Ordinal);
		Assert.DoesNotContain("K7QM-3XWD", await phone.GetStringAsync("/link?code=nonsense"), StringComparison.Ordinal);
	}

	[GeneratedRegex("data-since=\"(?<ms>\\d+)\"")]
	private static partial Regex Since();

	[GeneratedRegex("""<meta name="csrf-token" content="(?<token>[^"]+)">""")]
	private static partial Regex Csrf();

	[GeneratedRegex(@"pat_[A-Za-z0-9_\-]+")]
	private static partial Regex Key();

	[GeneratedRegex(@"cursor://anysphere\.cursor-deeplink/mcp/install\?name=pebble-audio&config=(?<config>[^""&\s]+)")]
	private static partial Regex CursorConfig();
}
