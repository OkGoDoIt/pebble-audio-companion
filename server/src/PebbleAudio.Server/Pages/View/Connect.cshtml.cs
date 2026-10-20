using System.Text;
using System.Text.Json;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;
using Microsoft.Extensions.Options;
using PebbleAudio.Server.Auth;
using PebbleAudio.Server.Data;
using PebbleAudio.Server.Mcp;
using PebbleAudio.Server.Sync;

namespace PebbleAudio.Server.Pages.View;

/// <summary>A Mac app that reads the archive, and how it connects (server/docs/connect-commands.md).</summary>
/// <param name="Key">The path segment: <c>/connect/{key}</c>.</param>
/// <param name="TokenName">What a fallback access key is called in the access list.</param>
/// <param name="Matches">Words in an access entry's name that mean this app.</param>
public sealed record ConnectTool(string Key, string Name, string TokenName, IReadOnlyList<string> Matches)
{
	public bool IsMatch(string name) => Matches.Any(m => name.Contains(m, StringComparison.OrdinalIgnoreCase));
}

/// <summary>
/// <c>/connect/{codex|claude-code|cursor}</c>: connecting a Mac app, built from the round-3 mockups 06a (Safari on the
/// iPhone), 06b (Codex), and 06c (Cursor). Every app signs in with OAuth by default, so the steps need no key; an
/// access key (<c>pat_…</c>) is the fallback for a Mac that cannot open a browser, minted here, shown once, and never
/// logged. "Who can read" lists live access the way <c>GET /sync/status</c> does, and the waiting row turns into a
/// check once the app appears, by a light poll while the page is open.
/// </summary>
public sealed class ConnectModel(
	IConnectedAssistants assistants,
	ApiTokenService tokens,
	SharingScopes scopes,
	IOptions<PebbleAudioOptions> options,
	TimeProvider time) : PageModel
{
	public static IReadOnlyList<ConnectTool> Tools { get; } =
	[
		new("codex", "Codex", "Codex on Mac", ["codex"]),
		new("claude-code", "Claude Code", "Claude Code on Mac", ["claude code", "claude-code"]),
		new("cursor", "Cursor", "Cursor on Mac", ["cursor"]),
	];

	public ConnectTool Tool { get; private set; } = Tools[0];

	public string Origin => options.Value.PublicOrigin;

	public string Host => new Uri(Origin).Authority;

	public string McpUrl => $"{Origin}/mcp";

	/// <summary>The access key just made, for this response only.</summary>
	public string? Key { get; private set; }

	public IReadOnlyList<WhoRow> Who { get; private set; } = [];

	/// <summary>When the page was opened (Unix milliseconds): the app has connected once it is seen after this.</summary>
	public long Since { get; private set; }

	public bool Ready { get; private set; }

	/// <summary>Opened in Safari on the iPhone: the command is copied there and pasted on the Mac.</summary>
	public bool OnIPhone => Request.Headers.UserAgent.ToString().Contains("iPhone", StringComparison.Ordinal);

	public async Task<IActionResult> OnGetAsync(string tool, CancellationToken cancellationToken)
	{
		if (Find(tool) is not { } found)
		{
			return NotFound();
		}

		Tool = found;
		Since = time.GetUtcNow().ToUnixTimeMilliseconds();
		await LoadWhoAsync(cancellationToken);
		return Page();
	}

	/// <summary>The "Who can read" list again, for the page's poll.</summary>
	public async Task<IActionResult> OnGetWhoAsync(string tool, long since, CancellationToken cancellationToken)
	{
		if (Find(tool) is not { } found)
		{
			return NotFound();
		}

		Tool = found;
		Since = since;
		await LoadWhoAsync(cancellationToken);
		Response.Headers.CacheControl = "no-store";
		return Partial("_Who", this);
	}

	/// <summary>The fallback: an access key named for the app, shown in this response and nowhere else.</summary>
	public async Task<IActionResult> OnPostKeyAsync(string tool, CancellationToken cancellationToken)
	{
		if (Find(tool) is not { } found)
		{
			return NotFound();
		}

		Tool = found;
		var userId = User.UserId() ?? throw new InvalidOperationException("The connect page requires a signed-in user.");
		(_, var secret) = await tokens.CreateAsync(userId, found.TokenName, TokenAccess.Read, cancellationToken);
		Key = secret;
		Since = time.GetUtcNow().ToUnixTimeMilliseconds();
		await LoadWhoAsync(cancellationToken);
		Response.Headers.CacheControl = "no-store";
		return Page();
	}

	// The commands (server/docs/connect-commands.md, verified 2026-10-21), OAuth first.

	public string OAuthCommand => Tool.Key switch
	{
		"codex" => $"codex mcp add pebble-audio --url {McpUrl}\ncodex mcp login pebble-audio",
		"claude-code" => $"claude mcp add --transport http --scope user pebble-audio {McpUrl}",
		_ => CursorLink(null),
	};

	/// <summary>The fallback's command with the key in it; the key itself is marked for the page to highlight.</summary>
	public string KeyCommand(string key) => Tool.Key switch
	{
		"codex" => $"echo 'export PEBBLE_AUDIO_KEY={key}' >> ~/.zshrc\nprintf '\\n[mcp_servers.pebble-audio]\\nurl = \"{McpUrl}\"\\nbearer_token_env_var = \"PEBBLE_AUDIO_KEY\"\\n' >> ~/.codex/config.toml",
		"claude-code" => $"claude mcp add --transport http --scope user pebble-audio {McpUrl} --header \"Authorization: Bearer {key}\"",
		_ => CursorLink(key),
	};

	/// <summary>Cursor's one-click install link: the server's URL, and the key's header in the fallback.</summary>
	public string CursorLink(string? key)
	{
		var config = key is null
			? JsonSerializer.Serialize(new { url = McpUrl })
			: JsonSerializer.Serialize(new { url = McpUrl, headers = new Dictionary<string, string> { ["Authorization"] = $"Bearer {key}" } });
		return $"cursor://anysphere.cursor-deeplink/mcp/install?name=pebble-audio&config={Uri.EscapeDataString(Convert.ToBase64String(Encoding.UTF8.GetBytes(config)))}";
	}

	public string ToolUrl(ConnectTool tool) => $"/connect/{tool.Key}";

	private static ConnectTool? Find(string? key) => Tools.FirstOrDefault(t => t.Key == key);

	private async Task LoadWhoAsync(CancellationToken cancellationToken)
	{
		var userId = User.UserId() ?? throw new InvalidOperationException("The connect page requires a signed-in user.");
		var zone = (await scopes.GetAsync(userId, cancellationToken)).TimeZone;
		var since = DateTimeOffset.FromUnixTimeMilliseconds(Since);
		var now = time.GetUtcNow();
		var entries = await assistants.ListAsync(userId, cancellationToken);
		// Connected for an OAuth app is its sign-in; a key only counts once the app has used it.
		bool Arrived(AccessEntry e) =>
			Tool.IsMatch(e.Name) && (e.LastUsedAt >= since || (e.Kind != TokenAssistantSource.KindName && e.ConnectedAt >= since));
		Ready = entries.Any(Arrived);
		var rows = entries.Select(e => new WhoRow(
			e.Name,
			Arrived(e) ? $"Connected {Speak.Ago(now - (e.LastUsedAt ?? e.ConnectedAt))}"
				: e.LastUsedAt is { } used ? $"Last read {Speak.Ago(now - used)}"
				: $"Connected {Days.Local(e.ConnectedAt, zone).ToString("MMM d", ViewText.English)}",
			Arrived(e),
			false)).ToList();
		if (!Ready)
		{
			// Waiting: the app's own row (it may have connected before and not read yet), else a row for it.
			var index = rows.FindIndex(r => Tool.IsMatch(r.Name));
			var waiting = new WhoRow(Tool.Name, "Waiting to connect", false, true);
			if (index >= 0)
			{
				rows[index] = rows[index] with { Waiting = true, Line = "Waiting for it to read" };
			}
			else
			{
				rows.Add(waiting);
			}
		}

		Who = rows;
	}
}

/// <param name="Line">"Connected Oct 12", "Last read 3 minutes ago", or "Waiting to connect".</param>
public sealed record WhoRow(string Name, string Line, bool Arrived, bool Waiting);
