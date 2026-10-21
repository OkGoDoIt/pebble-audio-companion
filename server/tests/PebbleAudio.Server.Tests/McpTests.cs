using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging.Abstractions;
using ModelContextProtocol.Client;
using ModelContextProtocol.Protocol;
using PebbleAudio.Server.Auth;
using PebbleAudio.Server.Data;
using PebbleAudio.Server.Mcp;

namespace PebbleAudio.Server.Tests;

[Collection(ServerCollection.Name)]
public sealed class McpTests(ArchiveServerFactory factory)
{
	private const string ToolsListBody = """{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}""";

	[Fact]
	public async Task An_unauthenticated_request_gets_a_401_that_points_at_the_resource_metadata()
	{
		using var client = factory.CreateClient();

		var response = await client.SendAsync(McpPost(token: null));

		Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
		var challenge = Assert.Single(response.Headers.WwwAuthenticate);
		Assert.Equal("Bearer", challenge.Scheme);
		Assert.Equal(
			$"resource_metadata=\"{ArchiveServerFactory.PublicOrigin}/.well-known/oauth-protected-resource/mcp\", scope=\"archive:read archive:write\"",
			challenge.Parameter);

		foreach (var path in new[] { "/.well-known/oauth-protected-resource/mcp", "/.well-known/oauth-protected-resource" })
		{
			using var metadata = JsonDocument.Parse(await client.GetStringAsync(path));
			var root = metadata.RootElement;
			Assert.Equal($"{ArchiveServerFactory.PublicOrigin}/mcp", root.GetProperty("resource").GetString());
			Assert.Equal([ArchiveServerFactory.PublicOrigin], root.GetProperty("authorization_servers").EnumerateArray().Select(e => e.GetString()));
			Assert.Equal([ArchiveScopes.Read, ArchiveScopes.Write], root.GetProperty("scopes_supported").EnumerateArray().Select(e => e.GetString()));
		}

		var unknown = await client.SendAsync(McpPost("pat_this-token-was-never-issued"));
		Assert.Equal(HttpStatusCode.Unauthorized, unknown.StatusCode);
	}

	[Fact]
	public async Task A_token_lists_tools_and_reads_only_its_own_users_status_until_revoked()
	{
		var userId = await factory.CreateUserAsync();
		var otherUserId = await factory.CreateUserAsync();
		string secret;
		Guid tokenId;
		await using (var scope = factory.Services.CreateAsyncScope())
		{
			var db = scope.ServiceProvider.GetRequiredService<ArchiveDbContext>();
			db.Conversations.Add(TestData.Conversation(userId, "conv-mine", "Mine"));
			db.Conversations.Add(TestData.Conversation(otherUserId, "conv-theirs-1", "Theirs"));
			db.Conversations.Add(TestData.Conversation(otherUserId, "conv-theirs-2", "Also theirs"));
			await db.SaveChangesAsync();

			var tokens = scope.ServiceProvider.GetRequiredService<ApiTokenService>();
			var (token, created) = await tokens.CreateAsync(userId, "Claude Code on the test Mac", TokenAccess.Read, CancellationToken.None);
			(secret, tokenId) = (created, token.Id);
		}

		Assert.StartsWith(ApiTokenService.Prefix, secret);

		var http = factory.CreateClient();
		var transport = new HttpClientTransport(
			new HttpClientTransportOptions
			{
				Endpoint = new Uri(http.BaseAddress!, "/mcp"),
				TransportMode = HttpTransportMode.StreamableHttp,
				AdditionalHeaders = new Dictionary<string, string> { ["Authorization"] = $"Bearer {secret}" },
			},
			http,
			NullLoggerFactory.Instance,
			ownsHttpClient: true);
		await using (var mcp = await McpClient.CreateAsync(transport))
		{
			Assert.Equal("Pebble Audio", mcp.ServerInfo.Name);
			Assert.True(Instructions.Lead.Length <= Instructions.LeadLimit);
			Assert.StartsWith(Instructions.Lead, mcp.ServerInstructions);

			var tool = Assert.Single(await mcp.ListToolsAsync(), t => t.Name == "get_status");
			Assert.True(tool.ProtocolTool.Annotations?.ReadOnlyHint);
			Assert.False(tool.ProtocolTool.Annotations?.OpenWorldHint);
			Assert.False(tool.ProtocolTool.Annotations?.DestructiveHint);
			Assert.NotNull(tool.ProtocolTool.OutputSchema);

			var result = await mcp.CallToolAsync("get_status");
			Assert.NotEqual(true, result.IsError);
			var structured = result.StructuredContent!.Value;
			var counts = structured.GetProperty("counts");
			Assert.Equal(1, counts.GetProperty("conversations").GetInt32());
			Assert.Equal(0, counts.GetProperty("transcripts").GetInt32());
			Assert.Equal("2026-10-14", structured.GetProperty("firstDay").GetString());
			Assert.True(DateTimeOffset.UtcNow - structured.GetProperty("serverTime").GetDateTimeOffset() < TimeSpan.FromMinutes(1));

			// content: the speakable summary, then the same JSON as the structured content.
			Assert.Equal(2, result.Content.Count);
			Assert.Equal(structured.GetProperty("summary").GetString(), Assert.IsType<TextContentBlock>(result.Content[0]).Text);
			var text = Assert.IsType<TextContentBlock>(result.Content[1]).Text;
			Assert.True(JsonNode.DeepEquals(JsonNode.Parse(text), JsonNode.Parse(structured.GetRawText())));
		}

		await using (var scope = factory.Services.CreateAsyncScope())
		{
			var db = scope.ServiceProvider.GetRequiredService<ArchiveDbContext>();
			var read = await db.AiReads.AsNoTracking().SingleAsync(r => r.UserId == userId);
			Assert.Equal("get_status", read.Tool);
			Assert.Equal("Claude Code on the test Mac", read.Client);
			Assert.Equal(tokenId, read.ApiTokenId);
			Assert.NotNull((await db.ApiTokens.AsNoTracking().SingleAsync(t => t.Id == tokenId)).LastUsedAt);

			// Caching hints (MCP 2026-07-28): the tool list depends on the connection and a resource is the person's
			// archive, so both are private; the prompts are the same for everyone.
			using (var raw = factory.CreateClient())
			{
				async Task<(string?, long)> HintsAsync(string method, object? parameters, string? name = null)
				{
					var request = McpRpc.Request(secret, method, parameters, perRequestMetadata: true);
					if (name is not null)
					{
						request.Headers.Add("Mcp-Name", name);
					}

					var listed = await McpRpc.ResultAsync(await raw.SendAsync(request));
					return (listed.GetProperty("cacheScope").GetString(), listed.GetProperty("ttlMs").GetInt64());
				}

				Assert.Equal(("private", 3_600_000L), await HintsAsync("tools/list", null));
				Assert.Equal(("public", 3_600_000L), await HintsAsync("prompts/list", null));
				Assert.Equal(("public", 3_600_000L), await HintsAsync("resources/templates/list", null));
				Assert.Equal(("private", 0L), await HintsAsync("resources/read", new { uri = "conversation://conv-mine" }, "conversation://conv-mine"));
			}

			await scope.ServiceProvider.GetRequiredService<ApiTokenService>().RevokeAsync(userId, tokenId, CancellationToken.None);
		}

		using var client = factory.CreateClient();
		var afterRevoke = await client.SendAsync(McpPost(secret));
		Assert.Equal(HttpStatusCode.Unauthorized, afterRevoke.StatusCode);
	}

	internal static HttpRequestMessage McpPost(string? token)
	{
		var request = new HttpRequestMessage(HttpMethod.Post, "/mcp")
		{
			Content = new StringContent(ToolsListBody, Encoding.UTF8, "application/json"),
		};
		request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
		request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("text/event-stream"));
		if (token is not null)
		{
			request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
		}

		return request;
	}
}
