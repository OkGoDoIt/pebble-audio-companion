using System.Collections.Concurrent;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Microsoft.Extensions.Options;
using ModelContextProtocol;
using ModelContextProtocol.Extensions.Apps;
using ModelContextProtocol.Protocol;
using ModelContextProtocol.Server;

namespace PebbleAudio.Server.Mcp;

/// <summary>
/// The three MCP Apps widgets (docs/research-verified-2026-10-20.md §3): the conversation card, the day timeline,
/// and the clip player. Each is one self-contained HTML document served as a <c>ui://</c> resource with the
/// MCP Apps MIME type. Its CSP allows our own origin for media (the clip audio) and nothing to connect to; the
/// widgets get everything else from the tool result. <c>ui.domain</c> is left unset: Claude accepts only its own
/// hash there and a wrong value means no render.
/// </summary>
/// <remarks>
/// A render tool points at its widget with <c>[McpAppUi]</c> and <c>[McpMeta("openai/outputTemplate", …)]</c> on its
/// definition (ChatGPT reads the alias, the MCP Apps hosts read <c>_meta.ui.resourceUri</c>). The URIs carry a
/// version because hosts cache widgets by URI: a change a cached copy cannot survive needs a new one.
/// </remarks>
public static class Widgets
{
	public const string ConversationCard = "ui://pebble/conversation-card.v3.html";

	public const string DayTimeline = "ui://pebble/day-timeline.v3.html";

	public const string ClipPlayer = "ui://pebble/clip-player.v3.html";

	/// <summary>The ChatGPT alias of <c>_meta.ui.resourceUri</c>.</summary>
	public const string OutputTemplateKey = "openai/outputTemplate";

	/// <summary>Every widget, with the file under <c>wwwroot/widgets/</c> it is composed from.</summary>
	public static IReadOnlyList<WidgetDefinition> All { get; } =
	[
		new(ConversationCard, "conversation-card", "Conversation card", "One conversation: title, time, summary, people, tags, quiet and lost audio, and a link to open it."),
		new(DayTimeline, "day-timeline", "Day timeline", "A day's conversations on a time axis with quiet and lost audio drawn to scale, or a run of days."),
		new(ClipPlayer, "clip-player", "Clip player", "Plays a clip of a conversation with its speakers' turns."),
	];

	/// <summary>Registers the widgets as resources and advertises MCP Apps support.</summary>
	public static IMcpServerBuilder WithWidgets(this IMcpServerBuilder builder)
	{
		builder.Services.AddSingleton<WidgetLibrary>();
		builder.Services.AddSingleton<IPostConfigureOptions<McpServerOptions>, WidgetRegistration>();
		return builder.WithMcpApps();
	}

	/// <summary>Adds the widget resources once the origin they allow is known.</summary>
	private sealed class WidgetRegistration(IOptions<PebbleAudioOptions> options, WidgetLibrary library) : IPostConfigureOptions<McpServerOptions>
	{
		public void PostConfigure(string? name, McpServerOptions server)
		{
			server.ResourceCollection ??= [];
			// Old chats can still reference v1 or v2. The result shapes remain compatible, so those
			// resources can safely use the same rendering while new calls fetch v3.
			foreach (var widget in All.Concat(All.SelectMany(w => new[] { 1, 2 }.Select(v => w with { Uri = w.Uri.Replace(".v3.", $".v{v}.", StringComparison.Ordinal) }))))
			{
				if (!server.ResourceCollection.TryGetPrimitive(widget.Uri, out _))
				{
					server.ResourceCollection.Add(new WidgetResource(widget, library, options.Value.PublicOrigin));
				}
			}
		}
	}
}

/// <param name="Uri">The <c>ui://</c> URI tools point at.</param>
/// <param name="File">The file's name under <c>wwwroot/widgets/</c>, without <c>.html</c>.</param>
/// <param name="Title">What a host may show for it.</param>
/// <param name="Description">One line on what it shows.</param>
public sealed record WidgetDefinition(string Uri, string File, string Title, string Description);

/// <summary>One widget as an MCP resource: the same HTML for every host, cached by hosts for an hour.</summary>
internal sealed class WidgetResource : McpServerResource
{
	private static readonly TimeSpan CacheFor = TimeSpan.FromHours(1);

	private readonly WidgetDefinition _widget;
	private readonly WidgetLibrary _library;
	private readonly JsonObject _meta;

	public WidgetResource(WidgetDefinition widget, WidgetLibrary library, string origin)
	{
		_widget = widget;
		_library = library;
		_meta = Meta(origin);
		ProtocolResource = new Resource
		{
			Uri = widget.Uri,
			Name = widget.File,
			Title = widget.Title,
			Description = widget.Description,
			MimeType = McpApps.HtmlMimeType,
			Meta = (JsonObject)_meta.DeepClone(),
		};
		ProtocolResourceTemplate = new ResourceTemplate
		{
			UriTemplate = widget.Uri,
			Name = widget.File,
			Title = widget.Title,
			Description = widget.Description,
			MimeType = McpApps.HtmlMimeType,
			Meta = (JsonObject)_meta.DeepClone(),
		};
	}

	public override ResourceTemplate ProtocolResourceTemplate { get; }

	public override Resource? ProtocolResource { get; }

	public override IReadOnlyList<object> Metadata { get; } = [];

	public override bool IsMatch(string uri) => string.Equals(uri, _widget.Uri, StringComparison.Ordinal);

	public override ValueTask<ReadResourceResult> ReadAsync(
		RequestContext<ReadResourceRequestParams> request,
		CancellationToken cancellationToken = default) =>
		ValueTask.FromResult(new ReadResourceResult
		{
			Contents =
			[
				new TextResourceContents
				{
					Uri = _widget.Uri,
					MimeType = McpApps.HtmlMimeType,
					Text = _library.Html(_widget.File),
					// The draft spec reads _meta.ui from resources/read before resources/list, so both carry it.
					Meta = (JsonObject)_meta.DeepClone(),
				},
			],
			TimeToLive = CacheFor,
			CacheScope = CacheScope.Public,
		});

	/// <summary>
	/// <c>_meta.ui</c>: no border (the widget draws its own card), our origin for the clip audio (resourceDomains is
	/// media-src among others), and no connections. <c>openai/widgetDescription</c> tells ChatGPT's model what the
	/// person already sees.
	/// </summary>
	private JsonObject Meta(string origin) => new()
	{
		["ui"] = new JsonObject
		{
			["prefersBorder"] = false,
			["csp"] = new JsonObject
			{
				["connectDomains"] = new JsonArray(),
				["resourceDomains"] = new JsonArray(origin),
			},
		},
		["openai/widgetDescription"] = _widget.Description,
		["openai/widgetPrefersBorder"] = false,
		["openai/widgetCSP"] = new JsonObject
		{
			["connect_domains"] = new JsonArray(),
			["resource_domains"] = new JsonArray(origin),
			// Open links leave through the host; ChatGPT asks for their domain here.
			["redirect_domains"] = new JsonArray(origin),
		},
	};
}

/// <summary>
/// Composes each widget into one HTML document from <c>wwwroot/widgets/{name}.html</c>. A line that is only
/// <c>/* @include path */</c> or <c>// @include path</c> is replaced by that file under <c>wwwroot</c>, so the widgets
/// share the viewer's tokens and its player instead of copies. In an included script, import lines and the
/// <c>export</c> keyword are dropped: the inline module is the files one after another.
/// </summary>
public sealed partial class WidgetLibrary(IWebHostEnvironment environment)
{
	private readonly ConcurrentDictionary<string, string> _composed = new(StringComparer.Ordinal);

	/// <summary>The composed document; read again on every call in development, so edits show at once.</summary>
	public string Html(string name)
	{
		if (Widgets.All.All(w => w.File != name))
		{
			throw new McpException($"There is no widget “{name}”.");
		}

		return environment.IsDevelopment() ? Compose(name) : _composed.GetOrAdd(name, Compose);
	}

	private string Compose(string name)
	{
		var page = Read($"widgets/{name}.html");
		return Include().Replace(page, match =>
		{
			var path = match.Groups["path"].Value;
			var text = Read(path);
			return path.EndsWith(".js", StringComparison.Ordinal)
				? Exports().Replace(Imports().Replace(text, ""), "")
				: text;
		});
	}

	private string Read(string path)
	{
		var file = environment.WebRootFileProvider.GetFileInfo(path);
		if (!file.Exists || file.IsDirectory)
		{
			throw new InvalidOperationException($"The widget file wwwroot/{path} is missing.");
		}

		using var stream = file.CreateReadStream();
		using var reader = new StreamReader(stream, Encoding.UTF8);
		return reader.ReadToEnd();
	}

	[GeneratedRegex(@"^[ \t]*(?:/\*|//)[ \t]*@include[ \t]+(?<path>[\w./-]+)[ \t]*(?:\*/)?[ \t]*$", RegexOptions.Multiline)]
	private static partial Regex Include();

	[GeneratedRegex(@"^import[ \t][^\n]*;[ \t]*\r?\n", RegexOptions.Multiline)]
	private static partial Regex Imports();

	[GeneratedRegex(@"^export[ \t]+(?=(?:async[ \t]+)?(?:function|const|let|class)\b)", RegexOptions.Multiline)]
	private static partial Regex Exports();
}
