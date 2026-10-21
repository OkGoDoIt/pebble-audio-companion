using System.Net.Http.Headers;
using System.Reflection;
using System.Text.Json;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Caching.Memory;
using PebbleAudio.Server.Data;

namespace PebbleAudio.Server.Auth;

/// <summary>
/// An OAuth app as the authorize and token endpoints see it, whichever way it identified itself.
/// </summary>
/// <param name="ClientId">The <c>client_id</c> it sent.</param>
/// <param name="Kind">Registered (RFC 7591) or a metadata document (CIMD).</param>
/// <param name="Name">The name it gives itself, if any.</param>
/// <param name="ClientUri">Its home page, if it gave an https one.</param>
/// <param name="LogoUri">Its logo, if it gave an https one.</param>
/// <param name="RedirectUris">Where sign-in may send the person back to.</param>
/// <param name="RowId">Its row in <c>OAuthClients</c>, once it has one.</param>
public sealed record ResolvedClient(
	string ClientId,
	OAuthClientKind Kind,
	string? Name,
	string? ClientUri,
	string? LogoUri,
	IReadOnlyList<string> RedirectUris,
	Guid? RowId)
{
	/// <summary>The host that serves a metadata-document client's id, shown on the consent page.</summary>
	public string? MetadataHost => Kind == OAuthClientKind.MetadataDocument ? new Uri(ClientId).Host : null;

	/// <summary>True when <paramref name="requested"/> matches one of the registered redirect URIs.</summary>
	public bool AllowsRedirect(string requested) =>
		RedirectUris.Any(registered => OAuthRedirects.Matches(registered, requested));
}

/// <summary>
/// What a client metadata document says, once it has been checked.
/// </summary>
public sealed record ClientMetadata(
	string ClientId,
	string? Name,
	string? ClientUri,
	string? LogoUri,
	IReadOnlyList<string> RedirectUris);

/// <summary>
/// Redirect URI rules (OAuth 2.1, RFC 8252): https anywhere, or http on a loopback host, never a fragment. Matching is
/// exact, except that a loopback registration matches the same host, path, and query on any port. One private-use
/// redirect is allowed by its exact scheme and host, Cursor's (<see cref="CursorAppScheme"/>); custom schemes are
/// otherwise refused, since any app on a device can claim one.
/// </summary>
public static class OAuthRedirects
{
	/// <summary>Cursor's desktop app returns to <c>cursor://anysphere.cursor-mcp/oauth/callback</c> on some installs.</summary>
	public const string CursorAppScheme = "cursor";

	public const string CursorAppHost = "anysphere.cursor-mcp";

	public static bool IsAllowed(string value) =>
		Uri.TryCreate(value, UriKind.Absolute, out var uri) &&
		uri.Fragment.Length == 0 &&
		string.IsNullOrEmpty(uri.UserInfo) &&
		uri.Host.Length > 0 &&
		(uri.Scheme == Uri.UriSchemeHttps || IsLoopback(uri) || IsKnownApp(uri));

	public static bool IsLoopback(Uri uri) =>
		uri.Scheme == Uri.UriSchemeHttp && uri.Host is "localhost" or "127.0.0.1" or "[::1]";

	public static bool IsLoopback(string value) =>
		Uri.TryCreate(value, UriKind.Absolute, out var uri) && IsLoopback(uri);

	/// <summary>A private-use redirect this server knows by its exact scheme and host, with no port.</summary>
	public static bool IsKnownApp(Uri uri) =>
		string.Equals(uri.Scheme, CursorAppScheme, StringComparison.Ordinal) &&
		string.Equals(uri.Host, CursorAppHost, StringComparison.Ordinal) &&
		uri.Port == -1;

	/// <summary>Sign-in returns to an app on the same device: a loopback port, or a known app's own address.</summary>
	public static bool ReturnsToDevice(string value) =>
		Uri.TryCreate(value, UriKind.Absolute, out var uri) && (IsLoopback(uri) || IsKnownApp(uri));

	public static bool Matches(string registered, string requested)
	{
		if (string.Equals(registered, requested, StringComparison.Ordinal))
		{
			return true;
		}

		if (!Uri.TryCreate(registered, UriKind.Absolute, out var r) ||
			!Uri.TryCreate(requested, UriKind.Absolute, out var q) ||
			!IsLoopback(r) ||
			!IsLoopback(q) ||
			q.Fragment.Length > 0)
		{
			return false;
		}

		return string.Equals(r.Host, q.Host, StringComparison.OrdinalIgnoreCase) &&
			string.Equals(r.AbsolutePath, q.AbsolutePath, StringComparison.Ordinal) &&
			string.Equals(r.Query, q.Query, StringComparison.Ordinal);
	}

	/// <summary>The host a redirect URI goes to, for the consent page and the admin area.</summary>
	public static string Host(string redirectUri) =>
		Uri.TryCreate(redirectUri, UriKind.Absolute, out var uri) ? uri.Host : redirectUri;
}

/// <summary>
/// The name people see for an app: the name it gives itself, else one recognized from where it sends people back
/// to, else that host.
/// </summary>
public static class OAuthClientNames
{
	public static string Display(string? name, string? redirectUri)
	{
		if (!string.IsNullOrWhiteSpace(name))
		{
			return name.Trim();
		}

		var host = redirectUri is null ? "" : OAuthRedirects.Host(redirectUri);
		foreach (var (domain, known) in KnownHosts)
		{
			if (IsHostOrSubdomain(host, domain))
			{
				return known;
			}
		}

		return host.Length > 0 ? host : "Unnamed app";
	}

	/// <summary>Where the assistants on the Connect pages return to, and their names (connect-commands.md).</summary>
	private static readonly (string Domain, string Name)[] KnownHosts =
	[
		("chatgpt.com", "ChatGPT"),
		("claude.ai", "Claude"),
		("gemini.google.com", "Gemini"),
		("oauth-redirect.googleusercontent.com", "Gemini"),
		("antigravity.google", "Antigravity"),
		("meta.ai", "Muse"),
		("muse.ai", "Muse"),
		("grok.com", "Grok"),
	];

	private static bool IsHostOrSubdomain(string host, string domain) =>
		host.Equals(domain, StringComparison.OrdinalIgnoreCase) ||
		host.EndsWith("." + domain, StringComparison.OrdinalIgnoreCase);
}

/// <summary>
/// Client ID Metadata Documents (draft-ietf-oauth-client-id-metadata-document-02, as the MCP spec uses them).
/// </summary>
public static class ClientMetadataDocuments
{
	public const int MaxNameLength = 200;

	/// <summary>An https client id is a metadata document URL; anything else is a registered client id.</summary>
	public static bool IsMetadataUrl(string clientId) => clientId.StartsWith("https://", StringComparison.Ordinal);

	/// <summary>
	/// https, a host, a path other than <c>/</c>, and no user info, fragment, or dot segments.
	/// </summary>
	public static bool IsValidUrl(string clientId)
	{
		if (!Uri.TryCreate(clientId, UriKind.Absolute, out var uri) ||
			uri.Scheme != Uri.UriSchemeHttps ||
			uri.Host.Length == 0 ||
			!string.IsNullOrEmpty(uri.UserInfo) ||
			clientId.Contains('#'))
		{
			return false;
		}

		var rawPath = clientId[(clientId.IndexOf(uri.Authority, StringComparison.OrdinalIgnoreCase) + uri.Authority.Length)..];
		rawPath = rawPath.Split('?')[0];
		if (rawPath.Length <= 1)
		{
			return false;
		}

		return !rawPath.Split('/').Any(segment => segment is "." or "..");
	}

	/// <summary>
	/// Checks a fetched document against its URL. Returns null, with the reason, when it must not be used.
	/// </summary>
	public static ClientMetadata? Parse(string clientId, ReadOnlySpan<byte> json, out string? problem)
	{
		try
		{
			using var document = JsonDocument.Parse(json.ToArray());
			return Parse(clientId, document.RootElement, out problem);
		}
		catch (JsonException)
		{
			problem = "the document is not JSON";
			return null;
		}
	}

	private static ClientMetadata? Parse(string clientId, JsonElement root, out string? problem)
	{
		if (root.ValueKind != JsonValueKind.Object)
		{
			problem = "the document is not a JSON object";
			return null;
		}

		if (!root.TryGetProperty("client_id", out var id) || id.ValueKind != JsonValueKind.String ||
			!string.Equals(id.GetString(), clientId, StringComparison.Ordinal))
		{
			problem = "its client_id is not the URL it was fetched from";
			return null;
		}

		if (root.TryGetProperty("client_secret", out _) || root.TryGetProperty("client_secret_expires_at", out _))
		{
			problem = "it carries a client secret";
			return null;
		}

		if (!root.TryGetProperty("redirect_uris", out var redirects) || redirects.ValueKind != JsonValueKind.Array ||
			redirects.GetArrayLength() == 0 ||
			redirects.EnumerateArray().Any(r => r.ValueKind != JsonValueKind.String || !OAuthRedirects.IsAllowed(r.GetString()!)))
		{
			problem = "its redirect_uris are missing or not https or loopback";
			return null;
		}

		// Public clients only. A client that prefers private_key_jwt (ChatGPT) also lists none, which is what it uses here.
		var method = StringProperty(root, "token_endpoint_auth_method");
		var methods = root.TryGetProperty("token_endpoint_auth_methods_supported", out var listed) && listed.ValueKind == JsonValueKind.Array
			? listed.EnumerateArray().Where(m => m.ValueKind == JsonValueKind.String).Select(m => m.GetString()).ToList()
			: [];
		if (method is not null && method != "none" && !methods.Contains("none"))
		{
			problem = $"it authenticates with {method}, and this server only takes public clients";
			return null;
		}

		var name = StringProperty(root, "client_name")?.Trim();
		if (name is { Length: > MaxNameLength })
		{
			name = name[..MaxNameLength];
		}

		problem = null;
		return new ClientMetadata(
			clientId,
			string.IsNullOrEmpty(name) ? null : name,
			HttpsOrNull(StringProperty(root, "client_uri")),
			HttpsOrNull(StringProperty(root, "logo_uri")),
			[.. redirects.EnumerateArray().Select(r => r.GetString()!)]);
	}

	internal static string? StringProperty(JsonElement root, string name) =>
		root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

	internal static string? HttpsOrNull(string? value) =>
		value is not null && Uri.TryCreate(value, UriKind.Absolute, out var uri) && uri.Scheme == Uri.UriSchemeHttps ? value : null;
}

/// <summary>
/// The metadata documents of ChatGPT, Claude, and Claude Code, shipped with the server (<c>Auth/KnownClients/</c>).
/// They are used when a live fetch fails: claude.ai has answered server fetches from some datacenter addresses
/// with a challenge page, and once the server advertises CIMD, Claude does not fall back to registration.
/// Refresh them with <c>curl -o Auth/KnownClients/&lt;name&gt;.json &lt;client id&gt;</c>.
/// </summary>
public static class KnownClients
{
	private const string ResourcePrefix = "KnownClients/";

	private static readonly Lazy<IReadOnlyDictionary<string, ClientMetadata>> Documents = new(Load);

	public static IReadOnlyDictionary<string, ClientMetadata> All => Documents.Value;

	public static ClientMetadata? Find(string clientId) => All.GetValueOrDefault(clientId);

	private static IReadOnlyDictionary<string, ClientMetadata> Load()
	{
		var assembly = Assembly.GetExecutingAssembly();
		var documents = new Dictionary<string, ClientMetadata>(StringComparer.Ordinal);
		foreach (var name in assembly.GetManifestResourceNames().Where(n => n.StartsWith(ResourcePrefix, StringComparison.Ordinal)))
		{
			using var stream = assembly.GetManifestResourceStream(name)!;
			using var memory = new MemoryStream();
			stream.CopyTo(memory);
			using var document = JsonDocument.Parse(memory.ToArray());
			var clientId = ClientMetadataDocuments.StringProperty(document.RootElement, "client_id")
				?? throw new InvalidOperationException($"{name} has no client_id.");
			var metadata = ClientMetadataDocuments.Parse(clientId, memory.ToArray(), out var problem)
				?? throw new InvalidOperationException($"{name} is not a usable client metadata document: {problem}.");
			documents[clientId] = metadata;
		}

		return documents;
	}
}

/// <summary>
/// Fetches client metadata documents: https only, public addresses only, no redirects, a 200 with at most 16 KB of
/// JSON within 3 seconds. A valid document is cached for its <c>Cache-Control</c> max-age, held between 5 minutes and
/// a day; a failure is never cached.
/// </summary>
public sealed class ClientMetadataFetcher(IHttpClientFactory httpClients, ILogger<ClientMetadataFetcher> logger)
	: IDisposable
{
	public const string HttpClientName = "oauth-client-metadata";

	public const int MaxBytes = 16 * 1024;

	private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(3);
	private static readonly TimeSpan ShortestCache = TimeSpan.FromMinutes(5);
	private static readonly TimeSpan LongestCache = TimeSpan.FromDays(1);

	private readonly MemoryCache _cache = new(new MemoryCacheOptions { SizeLimit = 256 });

	public async Task<ClientMetadata?> GetAsync(string clientId, CancellationToken cancellationToken)
	{
		if (_cache.TryGetValue(clientId, out ClientMetadata? cached))
		{
			return cached;
		}

		using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
		timeout.CancelAfter(Timeout);
		try
		{
			using var request = new HttpRequestMessage(HttpMethod.Get, clientId);
			request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
			request.Headers.UserAgent.Add(PublicHttp.UserAgent);
			using var response = await httpClients.CreateClient(HttpClientName)
				.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token);
			if (response.StatusCode != System.Net.HttpStatusCode.OK)
			{
				logger.LogWarning("The client metadata document {ClientId} answered {Status}.", clientId, (int)response.StatusCode);
				return null;
			}

			var body = await ReadLimitedAsync(response.Content, timeout.Token);
			if (body is null)
			{
				logger.LogWarning("The client metadata document {ClientId} is larger than {MaxBytes} bytes.", clientId, MaxBytes);
				return null;
			}

			var metadata = ClientMetadataDocuments.Parse(clientId, body, out var problem);
			if (metadata is null)
			{
				logger.LogWarning("The client metadata document {ClientId} was refused: {Problem}.", clientId, problem);
				return null;
			}

			var lifetime = response.Headers.CacheControl?.MaxAge ?? ShortestCache;
			lifetime = lifetime < ShortestCache ? ShortestCache : lifetime > LongestCache ? LongestCache : lifetime;
			_cache.Set(clientId, metadata, new MemoryCacheEntryOptions
			{
				AbsoluteExpirationRelativeToNow = lifetime,
				Size = 1,
			});
			return metadata;
		}
		catch (Exception ex) when (
			ex is HttpRequestException or IOException or OperationCanceledException &&
			!cancellationToken.IsCancellationRequested)
		{
			logger.LogWarning("The client metadata document {ClientId} could not be fetched: {Error}", clientId, ex.Message);
			return null;
		}
	}

	public void Dispose() => _cache.Dispose();

	private static async Task<byte[]?> ReadLimitedAsync(HttpContent content, CancellationToken cancellationToken)
	{
		if (content.Headers.ContentLength > MaxBytes)
		{
			return null;
		}

		await using var stream = await content.ReadAsStreamAsync(cancellationToken);
		var buffer = new byte[MaxBytes + 1];
		var read = 0;
		while (read < buffer.Length)
		{
			var count = await stream.ReadAsync(buffer.AsMemory(read), cancellationToken);
			if (count == 0)
			{
				break;
			}

			read += count;
		}

		return read > MaxBytes ? null : buffer[..read];
	}
}

/// <summary>
/// Turns a <c>client_id</c> into a <see cref="ResolvedClient"/>. A registered id is looked up; a metadata document is
/// fetched, falling back to the last copy that validated (its row) and then to the copy shipped with the server.
/// </summary>
public sealed class OAuthClientResolver(ArchiveDbContext db, ClientMetadataFetcher fetcher, TimeProvider time)
{
	public async Task<ResolvedClient?> ResolveAsync(string clientId, CancellationToken cancellationToken)
	{
		if (!ClientMetadataDocuments.IsMetadataUrl(clientId))
		{
			var registered = await db.OAuthClients.AsNoTracking()
				.SingleOrDefaultAsync(c => c.ClientId == clientId && c.Kind == OAuthClientKind.Registered, cancellationToken);
			return registered is null
				? null
				: new ResolvedClient(
					registered.ClientId,
					registered.Kind,
					NullIfEmpty(registered.Name),
					registered.ClientUri,
					registered.LogoUri,
					registered.RedirectUris,
					registered.Id);
		}

		if (!ClientMetadataDocuments.IsValidUrl(clientId))
		{
			return null;
		}

		var row = await db.OAuthClients.AsNoTracking().SingleOrDefaultAsync(c => c.ClientId == clientId, cancellationToken);
		var metadata = await fetcher.GetAsync(clientId, cancellationToken);
		if (metadata is null && row is { Kind: OAuthClientKind.MetadataDocument })
		{
			metadata = new ClientMetadata(row.ClientId, NullIfEmpty(row.Name), row.ClientUri, row.LogoUri, row.RedirectUris);
		}

		metadata ??= KnownClients.Find(clientId);
		return metadata is null
			? null
			: new ResolvedClient(
				clientId,
				OAuthClientKind.MetadataDocument,
				metadata.Name,
				metadata.ClientUri,
				metadata.LogoUri,
				metadata.RedirectUris,
				row?.Id);
	}

	/// <summary>
	/// True for a metadata-document client this server has never allowed and does not ship a copy of: resolving it
	/// would fetch its URL. The consent page has the person sign in before that, so an anonymous request cannot have
	/// the server fetch any public URL it names.
	/// </summary>
	public async Task<bool> IsUnseenDocumentAsync(string? clientId, CancellationToken cancellationToken) =>
		clientId is { Length: > 0 } &&
		ClientMetadataDocuments.IsMetadataUrl(clientId) &&
		KnownClients.Find(clientId) is null &&
		!await db.OAuthClients.AnyAsync(c => c.ClientId == clientId, cancellationToken);

	/// <summary>
	/// Returns the client's row id, creating the row for a metadata-document client on its first sign-in and keeping
	/// its stored copy up to date after that.
	/// </summary>
	public async Task<Guid> SaveAsync(ResolvedClient client, CancellationToken cancellationToken)
	{
		var now = time.GetUtcNow();
		var row = await db.OAuthClients.SingleOrDefaultAsync(c => c.ClientId == client.ClientId, cancellationToken);
		if (row is null)
		{
			row = new OAuthClient
			{
				Id = Guid.CreateVersion7(),
				ClientId = client.ClientId,
				Kind = client.Kind,
				CreatedAt = now,
			};
			db.OAuthClients.Add(row);
		}

		if (row.Kind == OAuthClientKind.MetadataDocument)
		{
			row.Name = client.Name ?? "";
			row.ClientUri = client.ClientUri;
			row.LogoUri = client.LogoUri;
			row.RedirectUris = [.. client.RedirectUris];
			row.MetadataFetchedAt = now;
		}

		await db.SaveChangesAsync(cancellationToken);
		return row.Id;
	}

	private static string? NullIfEmpty(string value) => value.Length == 0 ? null : value;
}
