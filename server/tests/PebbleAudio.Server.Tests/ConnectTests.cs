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
	private static readonly string[] HubTools = ["chatgpt", "claude", "claude-code", "codex", "cursor", "gemini", "muse", "pebble-plugin", "grok", "other"];

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

		// The default path is OAuth: one command, which starts the sign-in itself, and no key on the page.
		var page = WebUtility.HtmlDecode(await browser.GetStringAsync("/connect/codex"));
		Assert.Contains($"<pre class=\"cmd\" id=\"cmd\">codex mcp add pebble-audio --url {ArchiveServerFactory.PublicOrigin}/mcp</pre>", page, StringComparison.Ordinal);
		Assert.DoesNotContain("codex mcp login", page, StringComparison.Ordinal);
		Assert.Contains("once you sign in", page, StringComparison.Ordinal);
		Assert.DoesNotContain(ApiTokenService.Prefix, page, StringComparison.Ordinal);
		var since = Since().Match(page).Groups["ms"].Value;
		Assert.Contains("data-ready=\"false\"", page, StringComparison.Ordinal);

		// Cursor's button installs the server's URL, in the app or through cursor.com.
		var cursor = WebUtility.HtmlDecode(await browser.GetStringAsync("/connect/cursor"));
		var expectedConfig = $$"""{"url":"{{ArchiveServerFactory.PublicOrigin}}/mcp"}""";
		var config = CursorConfig().Match(cursor).Groups["config"].Value;
		Assert.Equal(expectedConfig, Encoding.UTF8.GetString(Convert.FromBase64String(Uri.UnescapeDataString(config))));
		Assert.Contains($"href=\"https://cursor.com/install-mcp?name=pebble-audio&config={config}\"", cursor, StringComparison.Ordinal);
		Assert.Contains("Or open in the browser", cursor, StringComparison.Ordinal);

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
		Assert.Matches(HubRow("claude-code", "On your Mac"), empty);
		Assert.Matches(HubRow("gemini", "Not connected"), empty);
		Assert.Matches(HubRow("muse", "On your watch or in Muse"), empty);
		Assert.Matches(HubRow("pebble-plugin", "In the Pebble app"), empty);
		Assert.Matches(HubRow("grok", "Not connected"), empty);
		Assert.Matches(HubRow("other", "Antigravity and others"), empty);
		Assert.Equal(HubTools, HubOrder().Matches(empty).Select(m => m.Groups["tool"].Value));

		// ChatGPT and Claude sign in, Gemini reads with an access key, and so does Antigravity: their rows are checked,
		// Antigravity gets a row of its own above Another assistant, and Claude Code comes with the Claude account.
		await ConnectAsync(userId, "ChatGPT", "https://chatgpt.com/connector_platform_oauth_redirect");
		await ConnectAsync(userId, "Claude", "https://claude.ai/api/mcp/auth_callback");
		foreach (var name in new[] { "Gemini", "Antigravity" })
		{
			string key;
			await using (var scope = factory.Services.CreateAsyncScope())
			{
				(_, key) = await scope.ServiceProvider.GetRequiredService<ApiTokenService>().CreateAsync(userId, name, TokenAccess.Read, CancellationToken.None);
			}

			using var api = factory.CreateClient();
			Assert.Equal(HttpStatusCode.OK, (await api.SendAsync(McpTests.McpPost(key))).StatusCode);
		}

		var hub = WebUtility.HtmlDecode(await browser.GetStringAsync("/connect"));
		Assert.Matches(HubRow("chatgpt", "Connected just now", connected: true), hub);
		Assert.Matches(HubRow("claude", "Connected just now", connected: true), hub);
		Assert.Matches(HubRow("claude-code", PebbleAudio.Server.Pages.View.ConnectHubModel.ClaudeAccountLine), hub);
		Assert.Matches(HubRow("gemini", "Connected just now", connected: true), hub);
		Assert.Matches(new Regex("<a class=\"row tall\" href=\"/connect/other\">\\s*<span class=\"itile\"[^>]*>A</span>\\s*<span class=\"grow\"><span class=\"t strong\">Antigravity</span><span class=\"s\">Connected just now</span>"), hub);

		// ChatGPT's own page says it is connected rather than waiting, and Claude Code's says Claude is there.
		var chatgpt = WebUtility.HtmlDecode(await browser.GetStringAsync("/connect/chatgpt"));
		Assert.Contains("data-ready=\"true\"", chatgpt, StringComparison.Ordinal);
		Assert.Contains("ChatGPT is connected.", chatgpt, StringComparison.Ordinal);
		var claudeCode = WebUtility.HtmlDecode(await browser.GetStringAsync("/connect/claude-code"));
		Assert.Contains("Claude is connected.", claudeCode, StringComparison.Ordinal);
		Assert.DoesNotContain("Waiting to connect", claudeCode, StringComparison.Ordinal);
	}

	[Fact]
	public async Task Each_assistant_page_gives_its_own_steps_in_the_phone_s_words()
	{
		var userId = await factory.CreateUserAsync();
		using var browser = await SignedInAsync(userId);
		var mcp = $"{ArchiveServerFactory.PublicOrigin}/mcp";

		// ChatGPT: its Plugins to open, its own labels in order ending with Install, the name and the address to copy
		// beside its fields, what each plan allows, and a wait for it.
		var chatgpt = WebUtility.HtmlDecode(await browser.GetStringAsync("/connect/chatgpt"));
		Assert.Contains("href=\"https://chatgpt.com/plugins\"", chatgpt, StringComparison.Ordinal);
		Assert.Contains("Open ChatGPT", chatgpt, StringComparison.Ordinal);
		Assert.Matches(new Regex("<b>\\+</b>.*Add custom MCP server.*Name.*Server URL.*Authentication.*OAuth.*I understand and want to continue.*Create as a plugin.*passkey.*Personal.*Install", RegexOptions.Singleline), chatgpt);
		Assert.Contains("data-copy-value=\"Pebble Audio\"", chatgpt, StringComparison.Ordinal);
		Assert.Contains($"data-copy-value=\"{mcp}\"", chatgpt, StringComparison.Ordinal);
		Assert.Contains("On Business, Enterprise, and Edu it can also add follow-ups and notes.", chatgpt, StringComparison.Ordinal);
		Assert.Contains("data-ready=\"false\"", chatgpt, StringComparison.Ordinal);
		Assert.Contains("Waiting for ChatGPT.", chatgpt, StringComparison.Ordinal);

		// ChatGPT on an iPhone opens its app, which can't add a server: the page says to use a computer instead.
		using (var iphone = new HttpRequestMessage(HttpMethod.Get, "/connect/chatgpt"))
		{
			iphone.Headers.UserAgent.ParseAdd("Mozilla/5.0 (iPhone; CPU iPhone OS 27_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Mobile/15E148 Safari/604.1");
			var onPhone = WebUtility.HtmlDecode(await (await browser.SendAsync(iphone)).Content.ReadAsStringAsync());
			Assert.DoesNotContain("href=\"https://chatgpt.com/plugins\"", onPhone, StringComparison.Ordinal);
			Assert.Contains($"data-copy-value=\"{ArchiveServerFactory.PublicOrigin}/connect/chatgpt\"", onPhone, StringComparison.Ordinal);
			Assert.Contains("Open it on a computer", onPhone, StringComparison.Ordinal);
		}

		// Claude: its Add custom connector dialog, prefilled with this server and the address encoded whole, and the same
		// dialog in admin settings for a Team or Enterprise Owner.
		var claude = WebUtility.HtmlDecode(await browser.GetStringAsync("/connect/claude"));
		var claudeQuery = $"?modal=add-custom-connector&connectorName=Pebble%20Audio&connectorUrl={Uri.EscapeDataString(mcp)}";
		Assert.Contains("connectorUrl=http%3A%2F%2Flocalhost%2Fmcp", claudeQuery, StringComparison.Ordinal);
		Assert.Contains($"href=\"https://claude.ai/customize/connectors{claudeQuery}\"", claude, StringComparison.Ordinal);
		Assert.Contains($"href=\"https://claude.ai/admin-settings/connectors{claudeQuery}\"", claude, StringComparison.Ordinal);
		Assert.Contains("Open Claude", claude, StringComparison.Ordinal);
		Assert.Contains("Waiting for Claude.", claude, StringComparison.Ordinal);

		// Claude Code: nothing to add with a Claude account; the command is for an API key.
		var claudeCode = WebUtility.HtmlDecode(await browser.GetStringAsync("/connect/claude-code"));
		Assert.Contains("nothing to install", claudeCode, StringComparison.Ordinal);
		Assert.Contains("href=\"/connect/claude\"", claudeCode, StringComparison.Ordinal);
		Assert.Contains($"claude mcp add --transport http --scope user pebble-audio {mcp}", claudeCode, StringComparison.Ordinal);
		Assert.Contains("Signed in with an API key", claudeCode, StringComparison.Ordinal);

		// Gemini: Connected Apps to open, its labels, the address to copy, and who it is for.
		var gemini = WebUtility.HtmlDecode(await browser.GetStringAsync("/connect/gemini"));
		Assert.Contains("href=\"https://gemini.google.com/apps\"", gemini, StringComparison.Ordinal);
		Assert.Matches(new Regex("Custom apps.*Add a custom app.*MCP server URL.*Next", RegexOptions.Singleline), gemini);
		Assert.Contains($"data-copy-value=\"{mcp}\"", gemini, StringComparison.Ordinal);
		Assert.Contains("Keep Activity", gemini, StringComparison.Ordinal);
		Assert.Contains("Waiting for Gemini.", gemini, StringComparison.Ordinal);

		// Grok: Connectors to open, its labels, the address to copy, and Grok Build's command.
		var grok = WebUtility.HtmlDecode(await browser.GetStringAsync("/connect/grok"));
		Assert.Contains("href=\"https://grok.com/connectors\"", grok, StringComparison.Ordinal);
		Assert.Matches(new Regex("New Connector.*Custom", RegexOptions.Singleline), grok);
		Assert.Contains($"data-copy-value=\"{mcp}\"", grok, StringComparison.Ordinal);
		Assert.Contains($"grok mcp add --transport http pebble-audio {mcp}", grok, StringComparison.Ordinal);
		Assert.Contains("Waiting for Grok.", grok, StringComparison.Ordinal);

		// Muse: pairing through the watch from the iPhone app, or a message for Muse to add the connector, and a wait.
		var muse = WebUtility.HtmlDecode(await browser.GetStringAsync("/connect/muse"));
		Assert.Contains("Muse connects through your watch", muse, StringComparison.Ordinal);
		Assert.Contains("Settings › Muse", muse, StringComparison.Ordinal);
		Assert.Contains($"<p id=\"prompt\">Create a custom connector named Pebble Audio for {mcp}</p>", muse, StringComparison.Ordinal);
		Assert.Contains("Copy Prompt", muse, StringComparison.Ordinal);
		Assert.Contains("href=\"https://muse.ai\"", muse, StringComparison.Ordinal);
		Assert.Contains("Waiting for Muse.", muse, StringComparison.Ordinal);
		var museCsrf = Csrf().Match(muse).Groups["token"].Value;
		var museKey = await browser.PostAsync("/connect/muse?handler=Key", new FormUrlEncodedContent(new Dictionary<string, string> { ["__RequestVerificationToken"] = museCsrf }));
		Assert.Equal(HttpStatusCode.NotFound, museKey.StatusCode);

		// Another assistant: the generic steps, Antigravity's settings, then an access key it may also add with, shown once.
		var other = WebUtility.HtmlDecode(await browser.GetStringAsync("/connect/other"));
		Assert.Contains("find where it adds a custom connector or server", other, StringComparison.Ordinal);
		Assert.Contains($"data-copy-value=\"{mcp}\"", other, StringComparison.Ordinal);
		Assert.Contains("~/.gemini/config/mcp_config.json", other, StringComparison.Ordinal);
		Assert.Contains($"\"serverUrl\": \"{mcp}\"", other, StringComparison.Ordinal);
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

	[GeneratedRegex("<a class=\"row tall\" href=\"/connect/(?<tool>[a-z-]+)\">")]
	private static partial Regex HubOrder();

	[GeneratedRegex("""<meta name="csrf-token" content="(?<token>[^"]+)">""")]
	private static partial Regex Csrf();

	[GeneratedRegex(@"pat_[A-Za-z0-9_\-]+")]
	private static partial Regex Key();

	[GeneratedRegex(@"cursor://anysphere\.cursor-deeplink/mcp/install\?name=pebble-audio&config=(?<config>[^""&\s]+)")]
	private static partial Regex CursorConfig();
}
