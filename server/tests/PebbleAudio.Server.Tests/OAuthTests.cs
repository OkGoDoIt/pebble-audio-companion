using System.Buffers.Text;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.WebUtilities;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using PebbleAudio.Server.Auth;
using PebbleAudio.Server.Data;
using PebbleAudio.Server.Sync;

namespace PebbleAudio.Server.Tests;

/// <summary>
/// The OAuth sign-ins ChatGPT, Claude, and Claude Code make, replayed against the test host with their real client
/// ids, redirect URIs, and request shapes (research-verified-2026-10-20.md §2).
/// </summary>
[Collection(ServerCollection.Name)]
public sealed partial class OAuthTests(ArchiveServerFactory factory)
{
	private const string Origin = ArchiveServerFactory.PublicOrigin;
	private const string Resource = Origin + "/mcp";

	private const string ClaudeClientId = "https://claude.ai/oauth/mcp-oauth-client-metadata";
	private const string ClaudeRedirect = "https://claude.ai/api/mcp/auth_callback";
	private const string ClaudeCodeClientId = "https://claude.ai/oauth/claude-code-client-metadata";
	private const string ChatGptClientId = "https://chatgpt.com/oauth/client.json";
	private const string ChatGptRedirect = "https://chatgpt.com/connector_platform_oauth_redirect";
	private const string ChatGptCallbackRedirect = "https://chatgpt.com/connector/oauth/cb_7f3a9c";

	[Fact]
	public async Task Claude_signs_in_through_its_metadata_document_and_refreshes_with_rotation_and_reuse_detection()
	{
		var userId = await factory.CreateUserAsync();
		using var browser = Browser();
		using var api = factory.CreateClient();

		// Discovery: one issuer string everywhere, S256, public clients, CIMD, iss on responses, and no OpenID.
		using (var metadata = JsonDocument.Parse(await api.GetStringAsync("/.well-known/oauth-authorization-server")))
		{
			var root = metadata.RootElement;
			Assert.Equal(Origin, root.GetProperty("issuer").GetString());
			Assert.Equal($"{Origin}/oauth/authorize", root.GetProperty("authorization_endpoint").GetString());
			Assert.Equal($"{Origin}/oauth/token", root.GetProperty("token_endpoint").GetString());
			Assert.Equal($"{Origin}/oauth/register", root.GetProperty("registration_endpoint").GetString());
			Assert.Equal(["S256"], Strings(root, "code_challenge_methods_supported"));
			Assert.Equal(["none"], Strings(root, "token_endpoint_auth_methods_supported"));
			Assert.Equal(["authorization_code", "refresh_token"], Strings(root, "grant_types_supported"));
			Assert.Equal(["code"], Strings(root, "response_types_supported"));
			Assert.Equal(["archive:read", "archive:write", "offline_access"], Strings(root, "scopes_supported"));
			Assert.True(root.GetProperty("client_id_metadata_document_supported").GetBoolean());
			Assert.True(root.GetProperty("authorization_response_iss_parameter_supported").GetBoolean());
		}

		using (var resourceMetadata = JsonDocument.Parse(await api.GetStringAsync("/.well-known/oauth-protected-resource/mcp")))
		{
			Assert.Equal([Origin], Strings(resourceMetadata.RootElement, "authorization_servers"));
			Assert.Equal(Resource, resourceMetadata.RootElement.GetProperty("resource").GetString());
		}

		Assert.Equal(HttpStatusCode.NotFound, (await api.GetAsync("/.well-known/openid-configuration")).StatusCode);

		// claude.ai answers this server's fetch with a challenge page (StubHttp's default); the shipped copy is used.
		var (verifier, challenge) = Pkce();
		var authorize = AuthorizeUrl(ClaudeClientId, ClaudeRedirect, challenge, "claude-state-1", "archive:read archive:write offline_access");

		// Signed out, the person goes through the passkey sign-in and comes back to the same request.
		var signedOut = await browser.GetAsync(authorize);
		Assert.Equal(HttpStatusCode.Redirect, signedOut.StatusCode);
		var login = new Uri(new Uri(Origin), signedOut.Headers.Location!);
		Assert.Equal("/sign-in", login.AbsolutePath);
		var returnUrl = QueryHelpers.ParseQuery(login.Query)["ReturnUrl"].ToString();
		Assert.Equal(authorize, returnUrl);

		// Signed out, the metadata document of an app this server has never seen is not fetched: sign-in comes first.
		const string unseen = "https://unseen-app.example/oauth/client.json";
		var unseenAnswer = await browser.GetAsync(AuthorizeUrl(unseen, "https://unseen-app.example/callback", challenge, "unseen"));
		Assert.Equal(HttpStatusCode.Redirect, unseenAnswer.StatusCode);
		Assert.Equal("/sign-in", new Uri(new Uri(Origin), unseenAnswer.Headers.Location!).AbsolutePath);
		Assert.DoesNotContain(factory.Http.Received, r => r.Request.RequestUri!.ToString() == unseen);

		await SignInAsync(browser, userId);
		var code = await AllowAsync(browser, returnUrl, ClaudeRedirect, "claude-state-1", expect: ["Connect Claude?", "claude.ai", "Add and update follow-ups, and add notes"]);

		// A wrong verifier fails PKCE and leaves the code unused; the right one gets the tokens.
		var wrongVerifier = await TokenAsync(api, new()
		{
			["grant_type"] = "authorization_code",
			["code"] = code,
			["redirect_uri"] = ClaudeRedirect,
			["client_id"] = ClaudeClientId,
			["code_verifier"] = Pkce().Verifier,
			["resource"] = Resource,
		});
		await AssertTokenErrorAsync(wrongVerifier, HttpStatusCode.BadRequest, "invalid_grant");

		var issued = await TokenAsync(api, new()
		{
			["grant_type"] = "authorization_code",
			["code"] = code,
			["redirect_uri"] = ClaudeRedirect,
			["client_id"] = ClaudeClientId,
			["code_verifier"] = verifier,
			["resource"] = Resource,
		});
		Assert.Equal(HttpStatusCode.OK, issued.StatusCode);
		Assert.Equal("no-store", issued.Headers.CacheControl?.ToString());
		var first = await TokensAsync(issued);
		Assert.StartsWith(OAuthServer.AccessTokenPrefix, first.Access);
		Assert.StartsWith(OAuthServer.RefreshTokenPrefix, first.Refresh);
		Assert.Equal(3600, first.ExpiresIn);
		Assert.Equal("archive:read archive:write offline_access", first.Scope);

		// The access token opens /mcp, write tools included.
		var tools = await ToolsAsync(api, first.Access);
		Assert.Contains("get_status", tools);
		Assert.Contains(TestWriteTools.Name, tools);

		// A refresh rotates both tokens.
		var second = await TokensAsync(await RefreshAsync(api, ClaudeClientId, first.Refresh));
		Assert.NotEqual(first.Refresh, second.Refresh);
		Assert.NotEqual(first.Access, second.Access);

		// The rotated token again within a minute is the client racing its own refresh: a fresh pair, still connected.
		var raced = await RefreshAsync(api, ClaudeClientId, first.Refresh);
		Assert.Equal(HttpStatusCode.OK, raced.StatusCode);

		// Later, a rotated token coming back means it leaked: the whole connection ends.
		await using (var scope = factory.Services.CreateAsyncScope())
		{
			var db = scope.ServiceProvider.GetRequiredService<ArchiveDbContext>();
			var hash = OAuthTokenService.Hash(first.Refresh);
			await db.OAuthTokens.Where(t => t.TokenHash == hash)
				.ExecuteUpdateAsync(s => s.SetProperty(t => t.UsedAt, DateTimeOffset.UtcNow - OAuthServer.RefreshReuseAllowance - TimeSpan.FromSeconds(5)));
		}

		await AssertTokenErrorAsync(await RefreshAsync(api, ClaudeClientId, first.Refresh), HttpStatusCode.BadRequest, "invalid_grant");
		Assert.Equal(HttpStatusCode.Unauthorized, (await api.SendAsync(McpTests.McpPost(second.Access))).StatusCode);
		await AssertTokenErrorAsync(await RefreshAsync(api, ClaudeClientId, second.Refresh), HttpStatusCode.BadRequest, "invalid_grant");
	}

	[Fact]
	public async Task ChatGPT_signs_in_through_registration_or_its_metadata_document_and_gets_only_the_scopes_it_was_allowed()
	{
		var userId = await factory.CreateUserAsync();
		using var browser = Browser();
		using var api = factory.CreateClient();
		await SignInAsync(browser, userId);

		// Dynamic registration: public clients with https or loopback redirect URIs only.
		var refused = await api.PostAsJsonAsync("/oauth/register", new
		{
			redirect_uris = new[] { "http://chatgpt.example/callback" },
			token_endpoint_auth_method = "none",
		});
		await AssertTokenErrorAsync(refused, HttpStatusCode.BadRequest, "invalid_redirect_uri");

		// ChatGPT's registration; it sends no client_name, so the app is named from where it returns to.
		var registered = await api.PostAsJsonAsync("/oauth/register", new
		{
			redirect_uris = new[] { ChatGptCallbackRedirect },
			grant_types = new[] { "authorization_code", "refresh_token" },
			response_types = new[] { "code" },
			token_endpoint_auth_method = "none",
			scope = "archive:read",
		});
		Assert.Equal(HttpStatusCode.Created, registered.StatusCode);
		string clientId;
		using (var registration = JsonDocument.Parse(await registered.Content.ReadAsStringAsync()))
		{
			clientId = registration.RootElement.GetProperty("client_id").GetString()!;
			Assert.StartsWith(OAuthServer.RegisteredClientPrefix, clientId);
			Assert.Equal("none", registration.RootElement.GetProperty("token_endpoint_auth_method").GetString());
			Assert.Equal([ChatGptCallbackRedirect], Strings(registration.RootElement, "redirect_uris"));
		}

		// An unknown client or an unregistered redirect is answered here, never redirected.
		var (verifier, challenge) = Pkce();
		var unknownClient = await browser.GetAsync(AuthorizeUrl("dcr_never-registered", ChatGptCallbackRedirect, challenge, "s"));
		Assert.Equal(HttpStatusCode.BadRequest, unknownClient.StatusCode);
		Assert.Contains("couldn&#x27;t identify the app", await unknownClient.Content.ReadAsStringAsync());
		var elsewhere = await browser.GetAsync(AuthorizeUrl(clientId, "https://attacker.example/callback", challenge, "s"));
		Assert.Equal(HttpStatusCode.BadRequest, elsewhere.StatusCode);

		// Other problems go back to the app with the error, its state, and iss.
		var wrongResource = await browser.GetAsync(AuthorizeUrl(clientId, ChatGptCallbackRedirect, challenge, "gpt-state-0", resource: "https://elsewhere.example/mcp"));
		AssertErrorRedirect(wrongResource, ChatGptCallbackRedirect, "invalid_target", "gpt-state-0");
		var plainPkce = await browser.GetAsync(AuthorizeUrl(clientId, ChatGptCallbackRedirect, challenge, "gpt-state-0").Replace("code_challenge_method=S256", "code_challenge_method=plain"));
		AssertErrorRedirect(plainPkce, ChatGptCallbackRedirect, "invalid_request", "gpt-state-0");

		// Deny.
		var authorize = AuthorizeUrl(clientId, ChatGptCallbackRedirect, challenge, "gpt-state-1", "archive:read");
		var consent = await browser.GetAsync(authorize);
		var html = await consent.Content.ReadAsStringAsync();
		Assert.Contains("Connect ChatGPT?", html);
		Assert.Contains("Not verified", html);
		Assert.Contains("chatgpt.com", html);
		Assert.DoesNotContain("Add and update follow-ups", html);
		var denied = await browser.PostAsync(authorize, Decision(html, "deny"));
		AssertErrorRedirect(denied, ChatGptCallbackRedirect, "access_denied", "gpt-state-1");

		// Allow, read only.
		var code = await AllowAsync(browser, authorize, ChatGptCallbackRedirect, "gpt-state-1", expect: []);
		var exchange = new Dictionary<string, string>
		{
			["grant_type"] = "authorization_code",
			["code"] = code,
			["redirect_uri"] = ChatGptCallbackRedirect,
			["client_id"] = clientId,
			["code_verifier"] = verifier,
			["resource"] = Resource,
		};
		var readOnly = await TokensAsync(await TokenAsync(api, exchange));
		Assert.Equal("archive:read", readOnly.Scope);

		// A read-only connection does not see write tools, and calling one says why.
		var tools = await ToolsAsync(api, readOnly.Access);
		Assert.Contains("get_status", tools);
		Assert.DoesNotContain(TestWriteTools.Name, tools);
		var write = await CallToolAsync(api, readOnly.Access, TestWriteTools.Name);
		Assert.True(write.GetProperty("isError").GetBoolean());
		Assert.Contains(McpScopeFilters.WriteNeeded, write.GetRawText());
		var stepUp = write.GetProperty("_meta").GetProperty("mcp/www_authenticate").GetString();
		Assert.Contains("error=\"insufficient_scope\"", stepUp);
		Assert.Contains("error_description=\"", stepUp);
		Assert.Contains($"resource_metadata=\"{Origin}/.well-known/oauth-protected-resource/mcp\"", stepUp);

		// The same code again: refused, and what the first exchange started is ended.
		await AssertTokenErrorAsync(await TokenAsync(api, exchange), HttpStatusCode.BadRequest, "invalid_grant");
		Assert.Equal(HttpStatusCode.Unauthorized, (await api.SendAsync(McpTests.McpPost(readOnly.Access))).StatusCode);

		// A week on, the cleanup deletes a registration that never connected and keeps this one, which ChatGPT reuses.
		var unused = await api.PostAsJsonAsync("/oauth/register", new { redirect_uris = new[] { ChatGptCallbackRedirect }, token_endpoint_auth_method = "none" });
		string unusedId;
		using (var registration = JsonDocument.Parse(await unused.Content.ReadAsStringAsync()))
		{
			unusedId = registration.RootElement.GetProperty("client_id").GetString()!;
		}

		await using (var scope = factory.Services.CreateAsyncScope())
		{
			var db = scope.ServiceProvider.GetRequiredService<ArchiveDbContext>();
			await db.OAuthClients.Where(c => c.ClientId == clientId || c.ClientId == unusedId)
				.ExecuteUpdateAsync(s => s.SetProperty(c => c.CreatedAt, DateTimeOffset.UtcNow - OAuthServer.UnusedRegistrationLifetime - TimeSpan.FromDays(1)));
			await scope.ServiceProvider.GetRequiredService<OAuthTokenService>().CleanUpAsync(CancellationToken.None);
		}

		Assert.Equal(HttpStatusCode.OK, (await browser.GetAsync(AuthorizeUrl(clientId, ChatGptCallbackRedirect, challenge, "gpt-state-again", "archive:read"))).StatusCode);
		Assert.Equal(HttpStatusCode.BadRequest, (await browser.GetAsync(AuthorizeUrl(unusedId, ChatGptCallbackRedirect, challenge, "gpt-state-unused"))).StatusCode);

		// ChatGPT's metadata document (fetched live through the stub), with write access.
		var (cimdVerifier, cimdChallenge) = Pkce();
		var cimdAuthorize = AuthorizeUrl(ChatGptClientId, ChatGptRedirect, cimdChallenge, "gpt-state-2", "archive:read archive:write");
		var cimdCode = await AllowAsync(browser, cimdAuthorize, ChatGptRedirect, "gpt-state-2", expect: ["Connect ChatGPT?", "Add and update follow-ups, and add notes"]);
		var cimdExchange = new Dictionary<string, string>
		{
			["grant_type"] = "authorization_code",
			["code"] = cimdCode,
			["redirect_uri"] = ChatGptRedirect,
			["client_id"] = ChatGptClientId,
			["code_verifier"] = cimdVerifier,
			["resource"] = Resource,
		};

		// It may prefer private_key_jwt, but here it is a public client: a client secret is refused.
		await AssertTokenErrorAsync(
			await TokenAsync(api, new Dictionary<string, string>(cimdExchange) { ["client_secret"] = "not-for-public-clients" }),
			HttpStatusCode.Unauthorized,
			"invalid_client");
		var readWrite = await TokensAsync(await TokenAsync(api, cimdExchange));
		Assert.Equal("archive:read archive:write", readWrite.Scope);
		var wrote = await CallToolAsync(api, readWrite.Access, TestWriteTools.Name);
		Assert.False(wrote.TryGetProperty("isError", out var isError) && isError.GetBoolean());

		// Who can read lists it, says what it may do (the phone has not allowed adding), and disconnects it.
		var apps = await browser.GetAsync("/access");
		Assert.Equal(HttpStatusCode.OK, apps.StatusCode);
		var appsHtml = WebUtility.HtmlDecode(await apps.Content.ReadAsStringAsync());
		Assert.Contains("ChatGPT", appsHtml);
		Assert.Contains("Can read\u00a0·", appsHtml);
		Assert.Contains("Disconnect ChatGPT?", appsHtml);
		var disconnect = DisconnectFormPattern().Match(appsHtml);
		Assert.True(disconnect.Success, "Who can read has no Disconnect form.");
		var disconnected = await browser.PostAsync(
			disconnect.Groups["action"].Value,
			new FormUrlEncodedContent(new Dictionary<string, string> { ["__RequestVerificationToken"] = disconnect.Groups["token"].Value }));
		Assert.Equal(HttpStatusCode.Redirect, disconnected.StatusCode);
		Assert.Equal(HttpStatusCode.Unauthorized, (await api.SendAsync(McpTests.McpPost(readWrite.Access))).StatusCode);
	}

	[Fact]
	public async Task Claude_Code_signs_in_on_any_loopback_port_and_the_phone_lists_and_revokes_the_connection()
	{
		var userId = await factory.CreateUserAsync();
		using var browser = Browser();
		using var api = factory.CreateClient();
		await SignInAsync(browser, userId);

		// Claude Code registers http://localhost/callback and listens on an ephemeral port.
		const string redirect = "http://localhost:53682/callback";
		var (verifier, challenge) = Pkce();
		var otherPath = await browser.GetAsync(AuthorizeUrl(ClaudeCodeClientId, "http://localhost:53682/elsewhere", challenge, "cc"));
		Assert.Equal(HttpStatusCode.BadRequest, otherPath.StatusCode);

		// The resource in another canonical spelling (a trailing slash, the host in capitals, the default port) is the
		// same resource; the path is not case-insensitive.
		var otherCase = await browser.GetAsync(AuthorizeUrl(ClaudeCodeClientId, redirect, challenge, "cc", resource: $"{Origin}/MCP"));
		AssertErrorRedirect(otherCase, redirect, "invalid_target", "cc");
		var code = await AllowAsync(
			browser,
			AuthorizeUrl(ClaudeCodeClientId, redirect, challenge, "cc-state", "archive:read", resource: "HTTP://LocalHost:80/mcp/"),
			redirect,
			"cc-state",
			expect: ["Connect Claude Code?", "An app on this device"]);
		var tokens = await TokensAsync(await TokenAsync(api, new()
		{
			["grant_type"] = "authorization_code",
			["code"] = code,
			["redirect_uri"] = redirect,
			["client_id"] = ClaudeCodeClientId,
			["code_verifier"] = verifier,
			["resource"] = $"{Origin}/mcp/",
		}));
		Assert.Equal(HttpStatusCode.OK, (await api.SendAsync(McpTests.McpPost(tokens.Access))).StatusCode);

		// The 401 that starts sign-in: the same challenge for no token, an unknown one, one for another audience,
		// and an expired one.
		var expectedChallenge = $"resource_metadata=\"{Origin}/.well-known/oauth-protected-resource/mcp\", scope=\"archive:read archive:write\"";
		foreach (var token in new string?[] { null, OAuthServer.AccessTokenPrefix + "never-issued" })
		{
			var response = await api.SendAsync(McpTests.McpPost(token));
			Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
			var header = Assert.Single(response.Headers.WwwAuthenticate);
			Assert.Equal("Bearer", header.Scheme);
			Assert.Equal(expectedChallenge, header.Parameter);
		}

		// A client running in a browser (the MCP Inspector) gets CORS on what it calls, with bearer tokens and never with
		// credentials; the admin area gets none.
		const string inspector = "https://inspector.example";
		foreach (var (path, method) in new[]
		{
			("/mcp", "POST"), ("/.well-known/oauth-protected-resource/mcp", "GET"), ("/.well-known/oauth-protected-resource", "GET"),
			("/.well-known/oauth-authorization-server", "GET"), ("/oauth/token", "POST"), ("/oauth/register", "POST"), ("/oauth/revoke", "POST"),
		})
		{
			var preflight = new HttpRequestMessage(HttpMethod.Options, path);
			preflight.Headers.Add("Origin", inspector);
			preflight.Headers.Add("Access-Control-Request-Method", method);
			preflight.Headers.Add("Access-Control-Request-Headers", "authorization,content-type,mcp-protocol-version");
			var allowed = await api.SendAsync(preflight);
			Assert.True(allowed.StatusCode == HttpStatusCode.NoContent, $"{path}: {(int)allowed.StatusCode}");
			Assert.Equal("*", Assert.Single(allowed.Headers.GetValues("Access-Control-Allow-Origin")));
			Assert.False(allowed.Headers.Contains("Access-Control-Allow-Credentials"), path);
		}

		var adminPreflight = new HttpRequestMessage(HttpMethod.Options, "/access");
		adminPreflight.Headers.Add("Origin", inspector);
		adminPreflight.Headers.Add("Access-Control-Request-Method", "POST");
		Assert.False((await api.SendAsync(adminPreflight)).Headers.Contains("Access-Control-Allow-Origin"));
		var fromBrowser = McpTests.McpPost(null);
		fromBrowser.Headers.Add("Origin", inspector);
		var signInNeeded = await api.SendAsync(fromBrowser);
		Assert.Equal(HttpStatusCode.Unauthorized, signInNeeded.StatusCode);
		Assert.Contains("WWW-Authenticate", string.Join(",", signInNeeded.Headers.GetValues("Access-Control-Expose-Headers")));
		var metadataRequest = new HttpRequestMessage(HttpMethod.Get, "/.well-known/oauth-protected-resource/mcp");
		metadataRequest.Headers.Add("Origin", inspector);
		var metadataAnswer = await api.SendAsync(metadataRequest);
		Assert.Equal(HttpStatusCode.OK, metadataAnswer.StatusCode);
		Assert.Equal("*", Assert.Single(metadataAnswer.Headers.GetValues("Access-Control-Allow-Origin")));

		await using (var scope = factory.Services.CreateAsyncScope())
		{
			var db = scope.ServiceProvider.GetRequiredService<ArchiveDbContext>();
			var hash = OAuthTokenService.Hash(tokens.Access);
			var grantId = await db.OAuthTokens.Where(t => t.TokenHash == hash).Select(t => t.GrantId).SingleAsync();

			await db.OAuthGrants.Where(g => g.Id == grantId).ExecuteUpdateAsync(s => s.SetProperty(g => g.Resource, "https://elsewhere.example/mcp"));
			var otherAudience = await api.SendAsync(McpTests.McpPost(tokens.Access));
			Assert.Equal(HttpStatusCode.Unauthorized, otherAudience.StatusCode);
			Assert.Equal(expectedChallenge, Assert.Single(otherAudience.Headers.WwwAuthenticate).Parameter);
			await db.OAuthGrants.Where(g => g.Id == grantId).ExecuteUpdateAsync(s => s.SetProperty(g => g.Resource, Resource));

			await db.OAuthTokens.Where(t => t.TokenHash == hash).ExecuteUpdateAsync(s => s.SetProperty(t => t.ExpiresAt, DateTimeOffset.UtcNow.AddSeconds(-1)));
			Assert.Equal(HttpStatusCode.Unauthorized, (await api.SendAsync(McpTests.McpPost(tokens.Access))).StatusCode);
		}

		var renewed = await TokensAsync(await RefreshAsync(api, ClaudeCodeClientId, tokens.Refresh));
		Assert.Equal(HttpStatusCode.OK, (await api.SendAsync(McpTests.McpPost(renewed.Access))).StatusCode);

		// The phone's access list: one entry for Claude Code, with its scopes and its last use.
		await using (var scope = factory.Services.CreateAsyncScope())
		{
			var source = scope.ServiceProvider.GetServices<IConnectedAssistantSource>().OfType<OAuthConnections>().Single();
			var entry = Assert.Single(await source.ListAsync(userId, CancellationToken.None));
			Assert.Equal("oauth", entry.Kind);
			Assert.Equal("Claude Code", entry.Name);
			Assert.Equal([ArchiveScopes.Read], entry.Scopes);
			Assert.NotNull(entry.LastUsedAt);
			Assert.True(DateTimeOffset.UtcNow - entry.ConnectedAt < TimeSpan.FromMinutes(5));

			// Revoking goes through the same composite the phone's DELETE /sync/access/{kind}/{id} uses.
			var everyone = scope.ServiceProvider.GetRequiredService<IConnectedAssistants>();
			Assert.False(await everyone.RevokeAsync(userId, "token", entry.Id, CancellationToken.None));
			Assert.True(await everyone.RevokeAsync(userId, entry.Kind, entry.Id, CancellationToken.None));
			Assert.Empty(await source.ListAsync(userId, CancellationToken.None));
		}

		Assert.Equal(HttpStatusCode.Unauthorized, (await api.SendAsync(McpTests.McpPost(renewed.Access))).StatusCode);
		await AssertTokenErrorAsync(await RefreshAsync(api, ClaudeCodeClientId, renewed.Refresh), HttpStatusCode.BadRequest, "invalid_grant");
	}

	[Fact]
	public async Task Gemini_Cursor_Muse_Grok_and_Antigravity_register_the_way_they_ask_and_sign_in_as_public_clients()
	{
		var userId = await factory.CreateUserAsync();
		using var browser = Browser();
		using var api = factory.CreateClient();
		await SignInAsync(browser, userId);

		// Gemini reportedly asks for client_secret_basic: it is registered as a public client, the answer says none and
		// carries no secret, and it signs in without one. client_secret_post is answered the same way.
		const string geminiRedirect = "https://gemini.google.com/oauth/callback";
		var gemini = await RegisterAsync(api, new { client_name = "Gemini", redirect_uris = new[] { geminiRedirect }, token_endpoint_auth_method = "client_secret_basic" });
		var post = await RegisterAsync(api, new { redirect_uris = new[] { geminiRedirect }, token_endpoint_auth_method = "client_secret_post" });
		Assert.NotEqual(gemini, post);
		await AssertTokenErrorAsync(
			await api.PostAsJsonAsync("/oauth/register", new { redirect_uris = new[] { geminiRedirect }, token_endpoint_auth_method = "private_key_jwt" }),
			HttpStatusCode.BadRequest,
			"invalid_client_metadata");
		await SignInAndReadAsync(browser, api, gemini, geminiRedirect, ["Connect Gemini?", "gemini.google.com"]);

		// Cursor's desktop app returns to its own address on some installs: that exact scheme and host, and no other
		// custom scheme, host, or port.
		const string cursorRedirect = "cursor://anysphere.cursor-mcp/oauth/callback";
		var cursor = await RegisterAsync(api, new { client_name = "Cursor", redirect_uris = new[] { cursorRedirect, "http://localhost:8787/callback" }, token_endpoint_auth_method = "none" });
		foreach (var refused in new[] { "cursor://evil.example/oauth/callback", "vscode://anysphere.cursor-mcp/oauth/callback", "cursor://anysphere.cursor-mcp:8080/oauth/callback" })
		{
			await AssertTokenErrorAsync(
				await api.PostAsJsonAsync("/oauth/register", new { redirect_uris = new[] { refused }, token_endpoint_auth_method = "none" }),
				HttpStatusCode.BadRequest,
				"invalid_redirect_uri");
		}

		var (_, challenge) = Pkce();
		Assert.Equal(HttpStatusCode.BadRequest, (await browser.GetAsync(AuthorizeUrl(cursor, "cursor://anysphere.cursor-mcp/elsewhere", challenge, "c"))).StatusCode);
		await SignInAndReadAsync(browser, api, cursor, cursorRedirect, ["Connect Cursor?", "An app on this device"]);

		// Muse (Meta), Grok, and Antigravity return to https addresses, Grok's with its trailing slash. One that gives no
		// name is named from where it returns to.
		const string museRedirect = "https://agent.meta.ai/api/hatch/oauth/callback";
		var muse = await RegisterAsync(api, new { redirect_uris = new[] { museRedirect } });
		await SignInAndReadAsync(browser, api, muse, museRedirect, ["Connect Muse?", "agent.meta.ai"]);
		const string grokRedirect = "https://grok.com/connectors-oauth-exchange-code/";
		var grok = await RegisterAsync(api, new { redirect_uris = new[] { grokRedirect }, token_endpoint_auth_method = "none" });
		Assert.Equal(HttpStatusCode.BadRequest, (await browser.GetAsync(AuthorizeUrl(grok, grokRedirect.TrimEnd('/'), challenge, "g"))).StatusCode);
		await SignInAndReadAsync(browser, api, grok, grokRedirect, ["Connect Grok?", "grok.com"]);
		const string antigravityRedirect = "https://antigravity.google/oauth-callback";
		var antigravity = await RegisterAsync(api, new { client_name = "Antigravity", redirect_uris = new[] { antigravityRedirect } });
		await SignInAndReadAsync(browser, api, antigravity, antigravityRedirect, ["Connect Antigravity?", "antigravity.google"]);
	}

	/// <summary>Registers a client (RFC 7591) and checks it was registered as a public client.</summary>
	private static async Task<string> RegisterAsync(HttpClient api, object metadata)
	{
		var response = await api.PostAsJsonAsync("/oauth/register", metadata);
		var body = await response.Content.ReadAsStringAsync();
		Assert.True(response.StatusCode == HttpStatusCode.Created, body);
		using var registration = JsonDocument.Parse(body);
		Assert.Equal("none", registration.RootElement.GetProperty("token_endpoint_auth_method").GetString());
		Assert.False(registration.RootElement.TryGetProperty("client_secret", out _), "A public client gets no secret.");
		return registration.RootElement.GetProperty("client_id").GetString()!;
	}

	/// <summary>Signs in through the consent page as a public client, exchanges the code without a secret, and reads.</summary>
	private async Task SignInAndReadAsync(HttpClient browser, HttpClient api, string clientId, string redirectUri, string[] expect)
	{
		var (verifier, challenge) = Pkce();
		var state = $"state-{Guid.NewGuid():N}";
		var code = await AllowAsync(browser, AuthorizeUrl(clientId, redirectUri, challenge, state, "archive:read"), redirectUri, state, expect);
		var tokens = await TokensAsync(await TokenAsync(api, new()
		{
			["grant_type"] = "authorization_code",
			["code"] = code,
			["redirect_uri"] = redirectUri,
			["client_id"] = clientId,
			["code_verifier"] = verifier,
			["resource"] = Resource,
		}));
		Assert.Equal("archive:read", tokens.Scope);
		Assert.Equal(HttpStatusCode.OK, (await api.SendAsync(McpTests.McpPost(tokens.Access))).StatusCode);
	}

	[Fact]
	public void Outbound_fetches_only_reach_public_addresses()
	{
		foreach (var blocked in new[] { "127.0.0.1", "10.0.0.5", "172.16.4.1", "192.168.1.1", "169.254.169.254", "100.64.0.1", "0.0.0.0", "::1", "fd00::1", "fe80::1", "::ffff:10.0.0.1" })
		{
			Assert.False(PublicHttp.IsPublic(IPAddress.Parse(blocked)), blocked);
		}

		foreach (var allowed in new[] { "134.209.0.150", "160.79.104.10", "2606:4700::6810:84e5" })
		{
			Assert.True(PublicHttp.IsPublic(IPAddress.Parse(allowed)), allowed);
		}

		// The shipped copies are valid metadata documents for the clients they stand in for.
		Assert.Equal(["ChatGPT", "Claude", "Claude Code"], KnownClients.All.Values.Select(c => c.Name!).Order());
		Assert.Equal([ClaudeRedirect], KnownClients.Find(ClaudeClientId)!.RedirectUris);
		Assert.Equal([ChatGptRedirect], KnownClients.Find(ChatGptClientId)!.RedirectUris);
	}

	private HttpClient Browser() =>
		factory.CreateClient(new WebApplicationFactoryClientOptions { AllowAutoRedirect = false, HandleCookies = true });

	private static async Task SignInAsync(HttpClient browser, Guid userId)
	{
		var response = await browser.GetAsync($"{TestSignIn.Path}?userId={userId}");
		Assert.True(response.StatusCode == HttpStatusCode.OK && response.Headers.Contains("Set-Cookie"), $"{(int)response.StatusCode} {response.Headers}");
	}

	private static (string Verifier, string Challenge) Pkce()
	{
		var verifier = Base64Url.EncodeToString(RandomNumberGenerator.GetBytes(32));
		return (verifier, Base64Url.EncodeToString(SHA256.HashData(Encoding.ASCII.GetBytes(verifier))));
	}

	private static string AuthorizeUrl(string clientId, string redirectUri, string challenge, string state, string? scope = null, string? resource = Resource)
	{
		var parameters = new Dictionary<string, string?>
		{
			["response_type"] = "code",
			["client_id"] = clientId,
			["redirect_uri"] = redirectUri,
			["code_challenge"] = challenge,
			["code_challenge_method"] = "S256",
			["state"] = state,
			["scope"] = scope,
			["resource"] = resource,
		};
		return QueryHelpers.AddQueryString("/oauth/authorize", parameters.Where(p => p.Value is not null));
	}

	/// <summary>Opens the consent page, checks what it says, allows, and returns the code from the redirect.</summary>
	private static async Task<string> AllowAsync(HttpClient browser, string authorize, string redirectUri, string state, string[] expect)
	{
		var consent = await browser.GetAsync(authorize);
		Assert.True(consent.StatusCode == HttpStatusCode.OK, $"{(int)consent.StatusCode} {consent.Headers.Location}");
		Assert.Equal("DENY", Assert.Single(consent.Headers.GetValues("X-Frame-Options")));
		var html = WebUtility.HtmlDecode(await consent.Content.ReadAsStringAsync());
		foreach (var text in expect)
		{
			Assert.Contains(text, html);
		}

		// It stands alone, without the site's menu, on the site's tokens and type.
		Assert.DoesNotContain("site-menu", html);
		Assert.Contains("/css/tokens.", html);
		Assert.Contains("/css/server.", html);
		Assert.Contains("will be able to", html);

		var allowed = await browser.PostAsync(authorize, Decision(html, "allow"));
		Assert.Equal(HttpStatusCode.Redirect, allowed.StatusCode);
		var location = allowed.Headers.Location!;
		Assert.StartsWith(redirectUri + "?", location.ToString());
		var query = QueryHelpers.ParseQuery(location.Query);
		Assert.Equal(state, query["state"].ToString());
		Assert.Equal(Origin, query["iss"].ToString());
		return query["code"].ToString();
	}

	private static FormUrlEncodedContent Decision(string html, string decision) => new(new Dictionary<string, string>
	{
		["__RequestVerificationToken"] = AntiforgeryPattern().Match(html).Groups[1].Value,
		["decision"] = decision,
	});

	private static void AssertErrorRedirect(HttpResponseMessage response, string redirectUri, string error, string state)
	{
		Assert.Equal(HttpStatusCode.Redirect, response.StatusCode);
		var location = response.Headers.Location!;
		Assert.StartsWith(redirectUri + "?", location.ToString());
		var query = QueryHelpers.ParseQuery(location.Query);
		Assert.Equal(error, query["error"].ToString());
		Assert.Equal(state, query["state"].ToString());
		Assert.Equal(Origin, query["iss"].ToString());
		Assert.False(query.ContainsKey("code"));
	}

	private static Task<HttpResponseMessage> TokenAsync(HttpClient api, Dictionary<string, string> form) =>
		api.PostAsync("/oauth/token", new FormUrlEncodedContent(form));

	private static Task<HttpResponseMessage> RefreshAsync(HttpClient api, string clientId, string refreshToken) =>
		TokenAsync(api, new()
		{
			["grant_type"] = "refresh_token",
			["refresh_token"] = refreshToken,
			["client_id"] = clientId,
			["resource"] = Resource,
		});

	private static async Task<(string Access, string Refresh, long ExpiresIn, string Scope)> TokensAsync(HttpResponseMessage response)
	{
		var body = await response.Content.ReadAsStringAsync();
		Assert.True(response.StatusCode == HttpStatusCode.OK, body);
		using var json = JsonDocument.Parse(body);
		var root = json.RootElement;
		Assert.Equal("Bearer", root.GetProperty("token_type").GetString());
		return (
			root.GetProperty("access_token").GetString()!,
			root.GetProperty("refresh_token").GetString()!,
			root.GetProperty("expires_in").GetInt64(),
			root.GetProperty("scope").GetString()!);
	}

	private static async Task AssertTokenErrorAsync(HttpResponseMessage response, HttpStatusCode status, string error)
	{
		var body = await response.Content.ReadAsStringAsync();
		Assert.True(response.StatusCode == status, $"{(int)response.StatusCode}: {body}");
		using var json = JsonDocument.Parse(body);
		Assert.Equal(error, json.RootElement.GetProperty("error").GetString());
	}

	private static async Task<List<string>> ToolsAsync(HttpClient api, string token)
	{
		var response = await api.SendAsync(McpTests.McpPost(token));
		Assert.Equal(HttpStatusCode.OK, response.StatusCode);
		var result = await McpRpc.ResultAsync(response);
		return [.. result.GetProperty("tools").EnumerateArray().Select(t => t.GetProperty("name").GetString()!)];
	}

	private static async Task<JsonElement> CallToolAsync(HttpClient api, string token, string name)
	{
		var response = await api.SendAsync(McpRpc.Request(token, "tools/call", new { name, arguments = new { } }));
		Assert.Equal(HttpStatusCode.OK, response.StatusCode);
		return await McpRpc.ResultAsync(response);
	}

	private static IReadOnlyList<string?> Strings(JsonElement root, string property) =>
		[.. root.GetProperty(property).EnumerateArray().Select(e => e.GetString())];

	[GeneratedRegex("<input name=\"__RequestVerificationToken\" type=\"hidden\" value=\"([^\"]+)\"")]
	private static partial Regex AntiforgeryPattern();

	[GeneratedRegex("<form method=\"post\"[^>]*action=\"(?<action>[^\"]*handler=Disconnect[^\"]*)\"[^>]*>.*?<input name=\"__RequestVerificationToken\" type=\"hidden\" value=\"(?<token>[^\"]+)\"", RegexOptions.Singleline)]
	private static partial Regex DisconnectFormPattern();
}

/// <summary>
/// Raw JSON-RPC over <c>/mcp</c>, for methods and shapes the SDK client does not expose.
/// </summary>
internal static class McpRpc
{
	private const string July2026 = "2026-07-28";

	/// <summary>
	/// A request; with <paramref name="perRequestMetadata"/> it is a 2026-07-28 request (protocol header, method
	/// header, and per-request <c>_meta</c>), the way ChatGPT sends MCP Events calls.
	/// </summary>
	public static HttpRequestMessage Request(string? token, string method, object? parameters, bool perRequestMetadata = false)
	{
		var node = parameters is null ? new System.Text.Json.Nodes.JsonObject() : System.Text.Json.Nodes.JsonNode.Parse(JsonSerializer.Serialize(parameters))!.AsObject();
		if (perRequestMetadata)
		{
			node["_meta"] = new System.Text.Json.Nodes.JsonObject
			{
				["io.modelcontextprotocol/protocolVersion"] = July2026,
				["io.modelcontextprotocol/clientCapabilities"] = new System.Text.Json.Nodes.JsonObject(),
				["io.modelcontextprotocol/clientInfo"] = new System.Text.Json.Nodes.JsonObject { ["name"] = "openai-mcp", ["version"] = "1.0.0" },
			};
		}

		var body = new System.Text.Json.Nodes.JsonObject { ["jsonrpc"] = "2.0", ["id"] = 1, ["method"] = method, ["params"] = node };
		var request = new HttpRequestMessage(HttpMethod.Post, "/mcp")
		{
			Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json"),
		};
		request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
		request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("text/event-stream"));
		if (perRequestMetadata)
		{
			request.Headers.Add("MCP-Protocol-Version", July2026);
			request.Headers.Add("Mcp-Method", method);
		}

		if (token is not null)
		{
			request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
		}

		return request;
	}

	/// <summary>The JSON-RPC message in a response, whether it came as JSON or as one server-sent event.</summary>
	public static async Task<JsonElement> MessageAsync(HttpResponseMessage response)
	{
		var text = await response.Content.ReadAsStringAsync();
		if (response.Content.Headers.ContentType?.MediaType == "text/event-stream")
		{
			text = string.Join("", text.Split('\n').Where(l => l.StartsWith("data:", StringComparison.Ordinal)).Select(l => l[5..].Trim()));
		}

		using var document = JsonDocument.Parse(text);
		return document.RootElement.Clone();
	}

	public static async Task<JsonElement> ResultAsync(HttpResponseMessage response)
	{
		var message = await MessageAsync(response);
		Assert.True(message.TryGetProperty("result", out var result), message.GetRawText());
		return result;
	}

	public static async Task<JsonElement> ErrorAsync(HttpResponseMessage response)
	{
		var message = await MessageAsync(response);
		Assert.True(message.TryGetProperty("error", out var error), message.GetRawText());
		return error;
	}
}
