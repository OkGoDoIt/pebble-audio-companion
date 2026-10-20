using System.Buffers.Binary;
using System.Text;

namespace PebbleAudio.Server.Tests;

/// <summary>
/// Builds the Ogg Speex file the phone uploads for a clip, the way ios/PebbleAudioKit/Sources/AudioCodec/OggSpeex.swift
/// remuxes it: the 80-byte Speex header alone on the first page, a comment page, then pages of 254 frames with a
/// running sample count as the granule. The frames are real watch frames from spec/fixtures.
/// </summary>
internal static class OggSpeexFile
{
	private const int SampleRate = 16_000;
	private const int FrameSamples = 320;
	private const int PacketsPerPage = 254;

	/// <summary>The 50 frames of spec/fixtures/speex_frames_v1.bin (one second), repeated <paramref name="seconds"/> times.</summary>
	public static byte[] FromFixture(int seconds = 1)
	{
		var bin = File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Fixtures", "speex_frames_v1.bin"));
		var frames = new List<byte[]>();
		for (var offset = 0; offset + 2 <= bin.Length;)
		{
			var length = BinaryPrimitives.ReadUInt16LittleEndian(bin.AsSpan(offset));
			frames.Add(bin.AsSpan(offset + 2, length).ToArray());
			offset += 2 + length;
		}

		return Encode([.. Enumerable.Repeat(frames, seconds).SelectMany(f => f)]);
	}

	public static byte[] Encode(IReadOnlyList<byte[]> frames)
	{
		using var output = new MemoryStream();
		uint sequence = 0;
		output.Write(Page(0x02, 0, sequence++, [Header()]));
		output.Write(Page(0x00, 0, sequence++, [Comment()]));
		for (var index = 0; index < frames.Count; index += PacketsPerPage)
		{
			var chunk = frames.Skip(index).Take(PacketsPerPage).ToList();
			var emitted = index + chunk.Count;
			output.Write(Page(emitted >= frames.Count ? (byte)0x04 : (byte)0x00, (long)emitted * FrameSamples, sequence++, chunk));
		}

		return output.ToArray();
	}

	private static byte[] Header()
	{
		var header = new byte[80];
		Encoding.ASCII.GetBytes("Speex   ").CopyTo(header, 0);
		Encoding.ASCII.GetBytes("speex-1.2").CopyTo(header, 8);
		int[] fields = [1, 80, SampleRate, 1, 4, 1, 9800, FrameSamples, 0, 1, 0, 0, 0];
		for (var i = 0; i < fields.Length; i++)
		{
			BinaryPrimitives.WriteInt32LittleEndian(header.AsSpan(28 + i * 4), fields[i]);
		}

		return header;
	}

	private static byte[] Comment()
	{
		var vendor = Encoding.ASCII.GetBytes("PebbleAudioKit");
		var packet = new byte[8 + vendor.Length];
		BinaryPrimitives.WriteUInt32LittleEndian(packet, (uint)vendor.Length);
		vendor.CopyTo(packet, 4);
		return packet;
	}

	private static byte[] Page(byte headerType, long granule, uint sequence, IReadOnlyList<byte[]> packets)
	{
		var page = new byte[27 + packets.Count + packets.Sum(p => p.Length)];
		Encoding.ASCII.GetBytes("OggS").CopyTo(page, 0);
		page[5] = headerType;
		BinaryPrimitives.WriteInt64LittleEndian(page.AsSpan(6), granule);
		BinaryPrimitives.WriteUInt32LittleEndian(page.AsSpan(14), 0x5042_4C41);
		BinaryPrimitives.WriteUInt32LittleEndian(page.AsSpan(18), sequence);
		page[26] = (byte)packets.Count;
		var offset = 27;
		foreach (var packet in packets)
		{
			page[offset++] = (byte)packet.Length;
		}

		foreach (var packet in packets)
		{
			packet.CopyTo(page, offset);
			offset += packet.Length;
		}

		BinaryPrimitives.WriteUInt32LittleEndian(page.AsSpan(22), Crc(page));
		return page;
	}

	/// <summary>Ogg's CRC-32: polynomial 0x04C11DB7, not reflected, initial value 0, no final XOR.</summary>
	private static uint Crc(byte[] bytes)
	{
		uint crc = 0;
		foreach (var b in bytes)
		{
			crc = (crc << 8) ^ Table[((crc >> 24) & 0xFF) ^ b];
		}

		return crc;
	}

	private static readonly uint[] Table = [.. Enumerable.Range(0, 256).Select(index =>
	{
		var value = (uint)index << 24;
		for (var bit = 0; bit < 8; bit++)
		{
			value = (value & 0x8000_0000) != 0 ? (value << 1) ^ 0x04C1_1DB7 : value << 1;
		}

		return value;
	})];
}

/// <summary>A fact that needs ffmpeg on the PATH; skipped, saying so, where there is none.</summary>
public sealed class FfmpegFactAttribute : FactAttribute
{
	public FfmpegFactAttribute()
	{
		if (!OnPath())
		{
			Skip = "ffmpeg is not on the PATH, so the clip transcode is not exercised here (brew install ffmpeg, or apt-get install ffmpeg).";
		}
	}

	private static bool OnPath() =>
		(Environment.GetEnvironmentVariable("PATH") ?? "")
			.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries)
			.Any(directory => File.Exists(Path.Combine(directory, "ffmpeg")));
}
