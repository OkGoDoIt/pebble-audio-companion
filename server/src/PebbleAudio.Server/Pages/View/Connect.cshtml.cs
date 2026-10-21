using System.ComponentModel.DataAnnotations;
using System.Text;
using System.Text.Json;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;
using Microsoft.Extensions.Options;
using PebbleAudio.Server.Auth;
using PebbleAudio.Server.Data;
using PebbleAudio.Server.Sync;

namespace PebbleAudio.Server.Pages.View;

/// <summary>How an assistant connects, which decides what its page says.</summary>
public enum ConnectKind
{
	/// <summary>Added in the assistant's own app or website as a custom connector, then signed in with the passkey.</summary>
	Web,

	/// <summary>A command or a one-click link on the Mac, then signed in with the passkey (or an access key).</summary>
	Mac,

	/// <summary>Meta's Muse, which connects through the watch from the iPhone app, not to this server.</summary>
	Muse,

	/// <summary>Any other assistant that can add a custom connector, or use an access key.</summary>
	Other,
}

/// <summary>An assistant the Connect an app page lists, and how it connects (server/docs/connect-commands.md).</summary>
/// <param name="Key">The path segment: <c>/connect/{key}</c>.</param>
/// <param name="Name">What the page and the hub call it.</param>
/// <param name="Subtitle">The hub's line under its name before it connects.</param>
/// <param name="TokenName">What an access key made for it is called in the access list.</param>
/// <param name="Matches">Words in an access entry's name that mean this assistant.</param>
/// <param name="Excludes">Words that mean another assistant despite a match (Claude Code is not Claude).</param>
public sealed record ConnectTool(
	string Key,
	string Name,
	ConnectKind Kind,
	string Subtitle,
	string TokenName,
	IReadOnlyList<string> Matches,
	IReadOnlyList<string>? Excludes = null)
{
	public bool IsMatch(string name) =>
		Matches.Any(m => name.Contains(m, StringComparison.OrdinalIgnoreCase)) &&
		!(Excludes ?? []).Any(m => name.Contains(m, StringComparison.OrdinalIgnoreCase));

	/// <summary>Its page waits for it to show up in Who can read, and says so.</summary>
	public bool Waits => Kind is ConnectKind.Web or ConnectKind.Mac;

	/// <summary>
	/// This assistant, connected: signed in with the passkey, or holding an access key it has used. A key nobody has
	/// used yet is still waiting for its app.
	/// </summary>
	public bool IsConnected(AccessEntry entry) =>
		IsMatch(entry.Name) && (entry.Kind != TokenAssistantSource.KindName || entry.LastUsedAt is not null);
}

/// <summary>
/// <c>/connect/{tool}</c>: connecting one assistant. ChatGPT and Claude are added in their own apps (round-3 05a, 05b);
/// Codex, Claude Code, and Cursor connect from the Mac (06a on the iPhone, 06b, 06c); Muse connects through the watch
/// from the iPhone app; anything else adds a custom connector or uses an access key (05d). Every assistant that can
/// signs in with OAuth, so the steps need no key; an access key (<c>pat_…</c>) is the fallback, minted here, shown
/// once, and never logged. "Who can read" lists live access the way <c>GET /sync/status</c> does, and the waiting row
/// turns into a check once the assistant appears, by a light poll while the page is open and in view.
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
		new("chatgpt", "ChatGPT", ConnectKind.Web, "Not connected", "ChatGPT", ["chatgpt"]),
		new("claude", "Claude", ConnectKind.Web, "Not connected", "Claude", ["claude"], ["claude code", "claude-code"]),
		new("codex", "Codex", ConnectKind.Mac, "On your Mac", "Codex on Mac", ["codex"]),
		new("claude-code", "Claude Code", ConnectKind.Mac, "On your Mac", "Claude Code on Mac", ["claude code", "claude-code"]),
		new("cursor", "Cursor", ConnectKind.Mac, "On your Mac", "Cursor on Mac", ["cursor"]),
		new("muse", "Muse", ConnectKind.Muse, "Through your watch", "Muse", ["muse"]),
		new("other", "Another assistant", ConnectKind.Other, "Gemini and others", "Another assistant", []),
	];

	/// <summary>The Mac tools, the segmented picker on their pages.</summary>
	public static IReadOnlyList<ConnectTool> MacTools { get; } = [.. Tools.Where(t => t.Kind == ConnectKind.Mac)];

	public ConnectTool Tool { get; private set; } = Tools[0];

	public string Origin => options.Value.PublicOrigin;

	public string Host => new Uri(Origin).Authority;

	/// <summary>The server address an assistant is given: what its Copy button copies.</summary>
	public string McpUrl => $"{Origin}/mcp";

	/// <summary>Claude's Add custom connector dialog with this server filled in (connect-commands.md).</summary>
	public string ClaudeUrl =>
		$"https://claude.ai/customize/connectors?modal=add-custom-connector&connectorName=Pebble%20Audio&connectorUrl={Uri.EscapeDataString(McpUrl)}";

	public const string ChatGptUrl = "https://chatgpt.com";

	/// <summary>The access key just made, for this response only.</summary>
	public string? Key { get; private set; }

	/// <summary>Another assistant's access key: what to call it, and whether it may add follow-ups and notes.</summary>
	[BindProperty]
	public KeyInput Input { get; set; } = new();

	public IReadOnlyList<WhoRow> Who { get; private set; } = [];

	/// <summary>When the page was opened (Unix milliseconds): the assistant has connected once it is seen after this.</summary>
	public long Since { get; private set; }

	public bool Ready { get; private set; }

	/// <summary>Opened in Safari on the iPhone: the command is copied there and pasted on the Mac.</summary>
	public bool OnIPhone => Request.Headers.UserAgent.ToString().Contains("iPhone", StringComparison.Ordinal);

	/// <summary>The waiting row's words, before the assistant shows up.</summary>
	public string WaitingLine => Key is null
		? $"Waiting for {Tool.Name}. It shows up here and in Pebble Audio once you sign in."
		: $"Waiting for {Tool.Name}. It shows up here and in Pebble Audio once it reads.";

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

	/// <summary>The fallback: an access key for this assistant, shown in this response and nowhere else.</summary>
	public async Task<IActionResult> OnPostKeyAsync(string tool, CancellationToken cancellationToken)
	{
		if (Find(tool) is not { } found || found.Kind is ConnectKind.Muse)
		{
			return NotFound();
		}

		Tool = found;
		if (!ModelState.IsValid)
		{
			Since = time.GetUtcNow().ToUnixTimeMilliseconds();
			await LoadWhoAsync(cancellationToken);
			return Page();
		}

		var userId = User.UserId() ?? throw new InvalidOperationException("The connect page requires a signed-in user.");
		var (name, access) = found.Kind == ConnectKind.Other
			? (string.IsNullOrWhiteSpace(Input.Name) ? found.TokenName : Input.Name.Trim(), Input.CanAdd ? TokenAccess.ReadWrite : TokenAccess.Read)
			: (found.TokenName, TokenAccess.Read);
		(_, var secret) = await tokens.CreateAsync(userId, name, access, cancellationToken);
		Key = secret;
		ModelState.Clear();
		Input = new KeyInput();
		Since = time.GetUtcNow().ToUnixTimeMilliseconds();
		await LoadWhoAsync(cancellationToken);
		Response.Headers.CacheControl = "no-store";
		return Page();
	}

	// The Mac tools' commands (server/docs/connect-commands.md, verified 2026-10-21), OAuth first.

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
		"cursor" => CursorLink(key),
		_ => key,
	};

	/// <summary>Cursor's one-click install link: the server's URL, and the key's header in the fallback.</summary>
	public string CursorLink(string? key)
	{
		var config = key is null
			? JsonSerializer.Serialize(new { url = McpUrl })
			: JsonSerializer.Serialize(new { url = McpUrl, headers = new Dictionary<string, string> { ["Authorization"] = $"Bearer {key}" } });
		return $"cursor://anysphere.cursor-deeplink/mcp/install?name=pebble-audio&config={Uri.EscapeDataString(Convert.ToBase64String(Encoding.UTF8.GetBytes(config)))}";
	}

	public static string ToolUrl(ConnectTool tool) => $"/connect/{tool.Key}";

	public static ConnectTool? Find(string? key) => Tools.FirstOrDefault(t => t.Key == key);

	private async Task LoadWhoAsync(CancellationToken cancellationToken)
	{
		var userId = User.UserId() ?? throw new InvalidOperationException("The connect page requires a signed-in user.");
		var zone = (await scopes.GetAsync(userId, cancellationToken)).TimeZone;
		var since = DateTimeOffset.FromUnixTimeMilliseconds(Since);
		var now = time.GetUtcNow();
		var entries = await assistants.ListAsync(userId, cancellationToken);
		// Connected for a signed-in assistant is its sign-in; a key only counts once the assistant has used it. One that
		// was connected before the page opened is connected too: the page says so instead of waiting for it.
		bool Here(AccessEntry e) => Tool.Waits && Tool.IsConnected(e);
		Ready = entries.Any(Here);
		var rows = entries.Select(e => new WhoRow(
			e.Name,
			Here(e) && (e.LastUsedAt ?? e.ConnectedAt) >= since ? SiteText.Connected(e.LastUsedAt ?? e.ConnectedAt, now, zone)
				: e.LastUsedAt is { } used ? SiteText.LastRead(used, now, zone)
				: SiteText.Connected(e.ConnectedAt, now, zone),
			Here(e),
			false)).ToList();
		if (!Ready && Tool.Waits)
		{
			// Waiting: the assistant's own row (it may have connected before and not read yet), else a row for it.
			var index = rows.FindIndex(r => Tool.IsMatch(r.Name));
			if (index >= 0)
			{
				rows[index] = rows[index] with { Waiting = true, Line = "Waiting for it to read" };
			}
			else
			{
				rows.Add(new WhoRow(Tool.Name, "Waiting to connect", false, true));
			}
		}

		Who = rows;
	}

	public sealed class KeyInput
	{
		[StringLength(80, ErrorMessage = "Keep the name under 80 characters.")]
		public string? Name { get; set; }

		public bool CanAdd { get; set; }
	}
}

/// <param name="Line">"Connected Oct 12", "Last read 3 min ago", or "Waiting to connect".</param>
public sealed record WhoRow(string Name, string Line, bool Arrived, bool Waiting);
