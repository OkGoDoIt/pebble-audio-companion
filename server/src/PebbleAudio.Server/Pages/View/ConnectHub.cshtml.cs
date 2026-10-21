using Microsoft.AspNetCore.Html;
using Microsoft.AspNetCore.Mvc.RazorPages;
using Microsoft.Extensions.Options;
using PebbleAudio.Server.Auth;
using PebbleAudio.Server.Sync;

namespace PebbleAudio.Server.Pages.View;

/// <summary>
/// <c>/connect</c>, Connect an app: one row per assistant, as the phone's Connect step lists them (round-3 05a-05e),
/// each opening its own page. A row shows Connected with a check once that assistant is in the live access list (the
/// same list as <c>GET /sync/status</c>'s <c>access</c>); an assistant this list does not know gets its own row above
/// "Another assistant".
/// </summary>
public sealed class ConnectHubModel(
	IConnectedAssistants assistants,
	SharingScopes scopes,
	IOptions<PebbleAudioOptions> options,
	TimeProvider time) : PageModel
{
	/// <summary>Claude Code's line once Claude is connected: signed in with that Claude account, it has the connector.</summary>
	public const string ClaudeAccountLine = "With your Claude account";

	public IReadOnlyList<HubRow> Rows { get; private set; } = [];

	public string Host => new Uri(options.Value.PublicOrigin).Authority;

	public string McpUrl => $"{options.Value.PublicOrigin}/mcp";

	public async Task OnGetAsync(CancellationToken cancellationToken)
	{
		var userId = User.UserId() ?? throw new InvalidOperationException("Connect an app requires a signed-in user.");
		var zone = (await scopes.GetAsync(userId, cancellationToken)).TimeZone;
		var now = time.GetUtcNow();
		var entries = await assistants.ListAsync(userId, cancellationToken);
		var known = ConnectModel.Tools.Where(t => t.Kind != ConnectKind.Other).ToList();
		var rows = new List<HubRow>();
		var claudeConnected = entries.Any(ConnectModel.Find("claude")!.IsConnected);
		foreach (var tool in known)
		{
			var entry = entries.FirstOrDefault(tool.IsConnected);
			rows.Add(new HubRow(
				ConnectModel.ToolUrl(tool),
				tool.Name,
				entry is not null ? SiteText.Connected(entry.ConnectedAt, now, zone)
					: tool.Key == "claude-code" && claudeConnected ? ClaudeAccountLine
					: tool.Subtitle,
				entry is not null,
				BrandMarks.Tile(tool.Name)));
		}

		// Connected assistants that are none of the above (Antigravity, a tool with an access key) sit above "Another
		// assistant".
		var other = ConnectModel.Find("other")!;
		rows.AddRange(entries
			.Where(e => !known.Any(t => t.IsMatch(e.Name)) && (e.Kind != TokenAssistantSource.KindName || e.LastUsedAt is not null))
			.Select(e => new HubRow(ConnectModel.ToolUrl(other), e.Name, SiteText.Connected(e.ConnectedAt, now, zone), true, BrandMarks.Tile(e.Name))));
		rows.Add(new HubRow(ConnectModel.ToolUrl(other), other.Name, other.Subtitle, false, BrandMarks.Others));
		Rows = rows;
	}
}

/// <param name="Line">"Not connected", "On your Mac", "With your Claude account", or "Connected Oct 12".</param>
public sealed record HubRow(string Url, string Name, string Line, bool Connected, IHtmlContent Tile);
