using System.Buffers.Binary;
using Microsoft.Extensions.Options;

namespace PebbleAudio.Server.Sync;

/// <summary>
/// Where clip audio lives: <c>PebbleAudio:ClipsPath</c>, one folder per user, files named by clip id. Paths in
/// the database are relative to the root, so the root can move.
/// </summary>
public sealed class ClipStorage(IOptions<PebbleAudioOptions> options, IHostEnvironment environment)
{
	public string Root { get; } = Path.GetFullPath(
		Path.Combine(environment.ContentRootPath, options.Value.ClipsPath is { Length: > 0 } path ? path : Path.Combine("App_Data", "clips")));

	/// <summary>The relative path of a clip's file with the given extension, for example <c>.ogg</c>.</summary>
	public static string RelativePath(Guid userId, Guid clipId, string extension) =>
		Path.Combine(userId.ToString("N"), clipId.ToString("N") + extension);

	public string Resolve(string relativePath)
	{
		var full = Path.GetFullPath(Path.Combine(Root, relativePath));
		return full.StartsWith(Root + Path.DirectorySeparatorChar, StringComparison.Ordinal)
			? full
			: throw new InvalidOperationException("A clip path points outside the clips folder.");
	}

	public string UserFolder(Guid userId) => Path.Combine(Root, userId.ToString("N"));

	/// <summary>Removes a file if it is there. Never throws: a file left behind costs disk, not correctness.</summary>
	public void Delete(string relativePath)
	{
		try
		{
			File.Delete(Resolve(relativePath));
		}
		catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidOperationException)
		{
		}
	}

	public void DeleteUser(Guid userId)
	{
		try
		{
			var folder = UserFolder(userId);
			if (Directory.Exists(folder))
			{
				Directory.Delete(folder, recursive: true);
			}
		}
		catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
		{
		}
	}
}

/// <summary>
/// Reads what an Ogg Speex file says about itself: its sample rate (the Speex header on the first page) and how
/// many samples it holds (the granule position of its last page). The phone's remux writes a running sample
/// count as the granule, so this is the audio's real length.
/// </summary>
public static class OggSpeexInfo
{
	private static ReadOnlySpan<byte> Capture => "OggS"u8;

	private static ReadOnlySpan<byte> SpeexMagic => "Speex   "u8;

	public static bool LooksLikeOgg(ReadOnlySpan<byte> start) => start.StartsWith(Capture);

	/// <summary>The duration in milliseconds, or null when the file is not Ogg Speex.</summary>
	public static long? DurationMs(string path)
	{
		var bytes = File.ReadAllBytes(path);
		return DurationMs(bytes);
	}

	public static long? DurationMs(ReadOnlySpan<byte> file)
	{
		// The first page carries the 80-byte Speex header alone: rate at offset 36 of the packet.
		if (file.Length < 28 || !file.StartsWith(Capture))
		{
			return null;
		}

		var segments = file[26];
		var packetStart = 27 + segments;
		if (file.Length < packetStart + 40 || !file[packetStart..].StartsWith(SpeexMagic))
		{
			return null;
		}

		var rate = BinaryPrimitives.ReadInt32LittleEndian(file.Slice(packetStart + 36, 4));
		if (rate <= 0)
		{
			return null;
		}

		// Walk the pages by their own lengths (a search for "OggS" could match inside audio).
		long granule = -1;
		var position = 0;
		while (position + 27 <= file.Length)
		{
			if (!file[position..].StartsWith(Capture))
			{
				return null;
			}

			var count = file[position + 26];
			if (position + 27 + count > file.Length)
			{
				return null;
			}

			var body = 0;
			foreach (var lacing in file.Slice(position + 27, count))
			{
				body += lacing;
			}

			var pageGranule = BinaryPrimitives.ReadInt64LittleEndian(file.Slice(position + 6, 8));
			if (pageGranule >= 0)
			{
				granule = pageGranule;
			}

			position += 27 + count + body;
		}

		return granule < 0 ? null : granule * 1000 / rate;
	}
}
