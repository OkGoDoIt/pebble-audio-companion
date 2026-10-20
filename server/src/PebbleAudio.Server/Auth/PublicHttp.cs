using System.Net;
using System.Net.Http.Headers;
using System.Net.Sockets;

namespace PebbleAudio.Server.Auth;

/// <summary>
/// Outbound HTTP to addresses someone else chose: OAuth client metadata documents and MCP Events webhooks. It
/// connects only to public addresses (resolved and checked at connect time, so a DNS answer cannot steer it to this
/// machine or the private network), never follows redirects, and keeps no cookies.
/// </summary>
public static class PublicHttp
{
	public static readonly ProductInfoHeaderValue UserAgent = new("PebbleAudio", AppVersion.Number);

	public static SocketsHttpHandler CreateHandler() => new()
	{
		AllowAutoRedirect = false,
		UseCookies = false,
		ConnectTimeout = TimeSpan.FromSeconds(3),
		PooledConnectionLifetime = TimeSpan.FromMinutes(5),
		ConnectCallback = ConnectToPublicAddressAsync,
	};

	/// <summary>
	/// True for an address on the public internet; false for loopback, private, shared, link-local, multicast,
	/// documentation, and reserved ranges, in IPv4, IPv6, and IPv4-mapped IPv6 forms.
	/// </summary>
	public static bool IsPublic(IPAddress address)
	{
		if (address.IsIPv4MappedToIPv6)
		{
			address = address.MapToIPv4();
		}

		if (address.AddressFamily == AddressFamily.InterNetwork)
		{
			var b = address.GetAddressBytes();
			return !(b[0] == 0 ||                                  // "this network"
				b[0] == 10 ||                                      // private
				(b[0] == 100 && b[1] >= 64 && b[1] <= 127) ||      // shared address space (CGNAT)
				b[0] == 127 ||                                     // loopback
				(b[0] == 169 && b[1] == 254) ||                    // link-local, cloud metadata
				(b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||       // private
				(b[0] == 192 && b[1] == 0 && b[2] == 0) ||         // IETF protocol assignments
				(b[0] == 192 && b[1] == 0 && b[2] == 2) ||         // documentation
				(b[0] == 192 && b[1] == 168) ||                    // private
				(b[0] == 198 && (b[1] == 18 || b[1] == 19)) ||     // benchmarking
				(b[0] == 198 && b[1] == 51 && b[2] == 100) ||      // documentation
				(b[0] == 203 && b[1] == 0 && b[2] == 113) ||       // documentation
				b[0] >= 224);                                      // multicast, reserved, broadcast
		}

		if (address.AddressFamily == AddressFamily.InterNetworkV6)
		{
			if (address.Equals(IPAddress.IPv6Loopback) || address.Equals(IPAddress.IPv6None) ||
				address.IsIPv6LinkLocal || address.IsIPv6SiteLocal || address.IsIPv6Multicast || address.IsIPv6UniqueLocal)
			{
				return false;
			}

			var b = address.GetAddressBytes();
			var isDocumentation = b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0d && b[3] == 0xb8;
			var isNat64 = b[0] == 0x00 && b[1] == 0x64 && b[2] == 0xff && b[3] == 0x9b;
			return !isDocumentation && !isNat64;
		}

		return false;
	}

	private static async ValueTask<Stream> ConnectToPublicAddressAsync(
		SocketsHttpConnectionContext context,
		CancellationToken cancellationToken)
	{
		var host = context.DnsEndPoint.Host;
		var addresses = IPAddress.TryParse(host, out var literal)
			? [literal]
			: await Dns.GetHostAddressesAsync(host, cancellationToken);
		var address = addresses.FirstOrDefault(IsPublic)
			?? throw new HttpRequestException($"{host} does not resolve to a public address.");

		var socket = new Socket(address.AddressFamily, SocketType.Stream, ProtocolType.Tcp) { NoDelay = true };
		try
		{
			await socket.ConnectAsync(address, context.DnsEndPoint.Port, cancellationToken);
			return new NetworkStream(socket, ownsSocket: true);
		}
		catch
		{
			socket.Dispose();
			throw;
		}
	}
}
