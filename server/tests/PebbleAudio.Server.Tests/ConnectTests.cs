using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.DependencyInjection;
using PebbleAudio.Server.Auth;
using PebbleAudio.Server.Data;

namespace PebbleAudio.Server.Tests;

/// <summary>
/// Connect an app: the hub at /connect, each assistant's page at /connect/{tool} (OAuth first, an access key only as
/// the fallback, shown once), Who can read with nobody connected, and the /link page a phone without the app opens
/// from the QR code.
/// </summary>
[Collection(ServerCollection.Name)]
public sealed partial class ConnectTests(ArchiveServerFactory factory)
{
	private static readonly string[] HubTools = ["chatgpt", "claude", "codex", "claude-code", "cursor", "muse", "other"];

	[Fact]
	public async Task Connecting_codex_signs_in_first_and_its_fallback_key_shows_once_and_turns_the_wait_into_a_check()
	{
		using var anonymous = factory.CreateClient(new WebApplicationFactoryClientOptions { AllowAutoRedirect = false });
		var redirect = await anonymous.GetAsync("/connect/codex");
		Assert.Equal(HttpStatusCode.Redirect, redirect.StatusCode);
		Assert.Contains("/sign-in", redirect.Headers.Location!.ToString(), StringComparison.Ordinal);

		var userId = await factory.CreateUserAsync();
		using var browser = await SignedInAsync(userId);
		Assert.Equal(HttpStatusCode.NotFound, (await browser.GetAsync("/connect/notepad")).StatusCode);

		// The default path is OAuth: no key on the page.
		var page = WebUtility.HtmlDecode(await browser.GetStringAsync("/connect/codex"));
		Assert.Contains($"codex mcp add pebble-audio --url {ArchiveServerFactory.PublicOrigin}/mcp", page, StringComparison.Ordinal);
		Assert.Contains("codex mcp login pebble-audio", page, StringComparison.Ordinal);
		Assert.Contains("once you sign in", page, StringComparison.Ordinal);
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
		Assert.Contains("once it reads", withKey, StringComparison.Ordinal);
		await using (var scope = factory.Services.CreateAsyncScope())
		{
			var listed = await scope.ServiceProvider.GetRequiredService<ApiTokenService>().ListAsync(userId, CancellationToken.None);
			var made = Assert.Single(listed);
			Assert.Equal("Codex on Mac", made.Name);
			Assert.Equal(TokenAccess.Read, made.Access);
		}

		Assert.DoesNotContain(key, await browser.GetStringAsync("/connect/codex"), StringComparison.Ordinal);

		// Codex waits until it reads with its key; then the list says it is connected, and so does the hub.
		var waiting = await browser.GetStringAsync($"/connect/codex?handler=Who&since={since}");
		Assert.Contains("data-ready=\"false\"", waiting, StringComparison.Ordinal);
		Assert.Contains("Waiting for it to read", waiting, StringComparison.Ordinal);
		Assert.Matches(HubRow("codex", "On your Mac"), await browser.GetStringAsync("/connect"));
		using (var codex = factory.CreateClient())
		{
			Assert.Equal(HttpStatusCode.OK, (await codex.SendAsync(McpTests.McpPost(key))).StatusCode);
		}

		var arrived = await browser.GetStringAsync($"/connect/codex?handler=Who&since={since}");
		Assert.Contains("data-ready=\"true\"", arrived, StringComparison.Ordinal);
		Assert.Contains("Codex on Mac", arrived, StringComparison.Ordinal);
		Assert.Matches(HubRow("codex", "Connected just now", connected: true), await browser.GetStringAsync("/connect"));

		// Opened again later, the page says Codex is connected instead of waiting for it.
		var later = WebUtility.HtmlDecode(await browser.GetStringAsync("/connect/codex"));
		Assert.Contains("data-ready=\"true\"", later, StringComparison.Ordinal);
		Assert.Contains("Codex is connected.", later, StringComparison.Ordinal);
	}

	[Fact]
	public async Task The_hub_lists_every_assistant_and_checks_the_ones_in_the_access_list()
	{
		var userId = await factory.CreateUserAsync();
		using var browser = await SignedInAsync(userId);

		// Nobody connected: a row for each, none checked, each opening its own page, and the address to copy.
		var empty = WebUtility.HtmlDecode(await browser.GetStringAsync("/connect"));
		foreach (var tool in HubTools)
		{
			Assert.Contains($"href=\"/connect/{tool}\"", empty, StringComparison.Ordinal);
			Assert.Equal(HttpStatusCode.OK, (await browser.GetAsync($"/connect/{tool}")).StatusCode);
		}

		Assert.DoesNotContain("aria-label=\"Connected\"", empty, StringComparison.Ordinal);
		Assert.Contains($"data-copy-value=\"{ArchiveServerFactory.PublicOrigin}/mcp\"", empty, StringComparison.Ordinal);
		Assert.Matches(HubRow("chatgpt", "Not connected"), empty);
		Assert.Matches(HubRow("muse", "Through your watch"), empty);
		Assert.Matches(HubRow("other", "Gemini and others"), empty);

		// ChatGPT signs in, and Gemini reads with an access key: ChatGPT's row is checked, and Gemini gets a row of its own.
		await ConnectAsync(userId, "ChatGPT", "https://chatgpt.com/connector_platform_oauth_redirect");
		string gemini;
		await using (var scope = factory.Services.CreateAsyncScope())
		{
			(_, gemini) = await scope.ServiceProvider.GetRequiredService<ApiTokenService>().CreateAsync(userId, "Gemini", TokenAccess.Read, CancellationToken.None);
		}

		using (var api = factory.CreateClient())
		{
			Assert.Equal(HttpStatusCode.OK, (await api.SendAsync(McpTests.McpPost(gemini))).StatusCode);
		}

		var hub = WebUtility.HtmlDecode(await browser.GetStringAsync("/connect"));
		Assert.Matches(HubRow("chatgpt", "Connected just now", connected: true), hub);
		Assert.Matches(HubRow("claude", "Not connected"), hub);
		Assert.Matches(new Regex("<a class=\"row tall\" href=\"/connect/other\">\\s*<span class=\"itile brand[^\"]*\"[^>]*><svg[^>]*><path fill=\"#8E75B2\"[^>]*/></svg></span>\\s*<span class=\"grow\"><span class=\"t strong\">Gemini</span><span class=\"s\">Connected just now</span>"), hub);

		// ChatGPT's own page says it is connected rather than waiting.
		var chatgpt = WebUtility.HtmlDecode(await browser.GetStringAsync("/connect/chatgpt"));
		Assert.Contains("data-ready=\"true\"", chatgpt, StringComparison.Ordinal);
		Assert.Contains("ChatGPT is connected.", chatgpt, StringComparison.Ordinal);
	}

	[Fact]
	public async Task Each_assistant_page_gives_its_own_steps_in_the_phone_s_words()
	{
		var userId = await factory.CreateUserAsync();
		using var browser = await SignedInAsync(userId);
		var mcp = $"{ArchiveServerFactory.PublicOrigin}/mcp";

		// ChatGPT: the address to copy, ChatGPT to open, its own labels in order, and a wait for it.
		var chatgpt = WebUtility.HtmlDecode(await browser.GetStringAsync("/connect/chatgpt"));
		Assert.Contains($"data-copy-value=\"{mcp}\"", chatgpt, StringComparison.Ordinal);
		Assert.Contains("href=\"https://chatgpt.com\"", chatgpt, StringComparison.Ordinal);
		Assert.Contains("Open ChatGPT", chatgpt, StringComparison.Ordinal);
		Assert.Matches(new Regex("Plugins.*Add custom MCP server.*Pebble Audio.*Server URL.*OAuth.*I understand and want to continue.*Create as a plugin.*passkey", RegexOptions.Singleline), chatgpt);
		Assert.Contains("data-ready=\"false\"", chatgpt, StringComparison.Ordinal);
		Assert.Contains("Waiting for ChatGPT.", chatgpt, StringComparison.Ordinal);

		// Claude: its Add custom connector dialog, prefilled with this server.
		var claude = WebUtility.HtmlDecode(await browser.GetStringAsync("/connect/claude"));
		Assert.Contains(
			$"href=\"https://claude.ai/customize/connectors?modal=add-custom-connector&connectorName=Pebble%20Audio&connectorUrl={Uri.EscapeDataString(mcp)}\"",
			claude,
			StringComparison.Ordinal);
		Assert.Contains("Open Claude", claude, StringComparison.Ordinal);
		Assert.Contains("Waiting for Claude.", claude, StringComparison.Ordinal);

		// Muse: it connects through the watch from the iPhone app, and the page invents no steps for it.
		var muse = WebUtility.HtmlDecode(await browser.GetStringAsync("/connect/muse"));
		Assert.Contains("Muse connects through your watch", muse, StringComparison.Ordinal);
		Assert.Contains("Settings › Muse", muse, StringComparison.Ordinal);
		Assert.DoesNotContain("open-steps", muse, StringComparison.Ordinal);
		Assert.DoesNotContain("<div class=\"wait\"", muse, StringComparison.Ordinal);
		Assert.DoesNotContain(mcp, muse, StringComparison.Ordinal);
		var museCsrf = Csrf().Match(muse).Groups["token"].Value;
		var museKey = await browser.PostAsync("/connect/muse?handler=Key", new FormUrlEncodedContent(new Dictionary<string, string> { ["__RequestVerificationToken"] = museCsrf }));
		Assert.Equal(HttpStatusCode.NotFound, museKey.StatusCode);

		// Another assistant: the generic steps, then an access key it may also add with, shown once.
		var other = WebUtility.HtmlDecode(await browser.GetStringAsync("/connect/other"));
		Assert.Contains("find where it adds a custom connector or server", other, StringComparison.Ordinal);
		Assert.Contains($"data-copy-value=\"{mcp}\"", other, StringComparison.Ordinal);
		Assert.Contains("Make an Access Key", other, StringComparison.Ordinal);
		var csrf = Csrf().Match(other).Groups["token"].Value;
		var minted = await browser.PostAsync("/connect/other?handler=Key", new FormUrlEncodedContent(new Dictionary<string, string>
		{
			["__RequestVerificationToken"] = csrf,
			["Input.Name"] = "Gemini CLI",
			["Input.CanAdd"] = "true",
		}));
		Assert.Equal(HttpStatusCode.OK, minted.StatusCode);
		Assert.True(minted.Headers.CacheControl?.NoStore, "A page with a new key must not be stored.");
		var key = Key().Match(await minted.Content.ReadAsStringAsync()).Value;
		Assert.StartsWith(ApiTokenService.Prefix, key);
		await using (var scope = factory.Services.CreateAsyncScope())
		{
			var made = Assert.Single(await scope.ServiceProvider.GetRequiredService<ApiTokenService>().ListAsync(userId, CancellationToken.None));
			Assert.Equal("Gemini CLI", made.Name);
			Assert.Equal(TokenAccess.ReadWrite, made.Access);
		}

		Assert.DoesNotContain(key, await browser.GetStringAsync("/connect/other"), StringComparison.Ordinal);
	}

	[Fact]
	public async Task Who_can_read_with_nobody_connected_points_to_the_hub_and_never_at_the_address()
	{
		var userId = await factory.CreateUserAsync();
		using var browser = await SignedInAsync(userId);

		var page = WebUtility.HtmlDecode(await browser.GetStringAsync("/access"));

		Assert.Contains("No assistant is connected yet.", page, StringComparison.Ordinal);
		Assert.Matches(new Regex("<a class=\"[^\"]*\" href=\"/connect\">Connect an App</a>"), page);
		Assert.DoesNotContain("/mcp", page, StringComparison.Ordinal);
		Assert.DoesNotContain("Disconnect", page, StringComparison.Ordinal);
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
		Assert.DoesNotContain("site-menu", page, StringComparison.Ordinal);
		Assert.DoesNotContain("K7QM-3XWD", await phone.GetStringAsync("/link?code=nonsense"), StringComparison.Ordinal);
	}

	private async Task<HttpClient> SignedInAsync(Guid userId)
	{
		var browser = factory.CreateClient(new WebApplicationFactoryClientOptions { AllowAutoRedirect = false });
		Assert.Equal(HttpStatusCode.OK, (await browser.GetAsync($"{TestSignIn.Path}?userId={userId}")).StatusCode);
		return browser;
	}

	/// <summary>A live OAuth connection for the user, as a finished sign-in leaves it.</summary>
	private async Task ConnectAsync(Guid userId, string name, string redirectUri)
	{
		await using var scope = factory.Services.CreateAsyncScope();
		var db = scope.ServiceProvider.GetRequiredService<ArchiveDbContext>();
		var now = DateTimeOffset.UtcNow;
		var client = new OAuthClient
		{
			Id = Guid.CreateVersion7(),
			ClientId = $"test-{Guid.NewGuid():N}",
			Kind = OAuthClientKind.Registered,
			Name = name,
			RedirectUris = [redirectUri],
			CreatedAt = now,
		};
		db.OAuthClients.Add(client);
		db.OAuthGrants.Add(new OAuthGrant
		{
			Id = Guid.CreateVersion7(),
			UserId = userId,
			OAuthClientId = client.Id,
			Scopes = [ArchiveScopes.Read],
			Resource = $"{ArchiveServerFactory.PublicOrigin}/mcp",
			RedirectUri = redirectUri,
			CreatedAt = now,
			ExpiresAt = now.AddDays(60),
		});
		await db.SaveChangesAsync();
	}

	/// <summary>The hub's row for a tool: its name's line, and a check when connected.</summary>
	private static Regex HubRow(string tool, string line, bool connected = false) => new(
		$"<a class=\"row tall\" href=\"/connect/{Regex.Escape(tool)}\">(?:(?!</a>).)*?<span class=\"s\">{Regex.Escape(line)}</span></span>\\s*" +
		(connected ? "<span class=\"check-badge\"" : "<svg class=\"chev\""),
		RegexOptions.Singleline);

	[GeneratedRegex("data-since=\"(?<ms>\\d+)\"")]
	private static partial Regex Since();

	[GeneratedRegex("""<meta name="csrf-token" content="(?<token>[^"]+)">""")]
	private static partial Regex Csrf();

	[GeneratedRegex(@"pat_[A-Za-z0-9_\-]+")]
	private static partial Regex Key();

	[GeneratedRegex(@"cursor://anysphere\.cursor-deeplink/mcp/install\?name=pebble-audio&config=(?<config>[^""&\s]+)")]
	private static partial Regex CursorConfig();
}
