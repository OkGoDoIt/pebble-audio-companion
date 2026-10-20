using System.Diagnostics;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;
using PebbleAudio.Server.Data;
using PebbleAudio.Server.Jobs;
using PebbleAudio.Server.Settings;

namespace PebbleAudio.Server.Sync;

/// <summary>
/// Turns an uploaded Ogg Speex clip into AAC in an m4a (16 kHz mono, moov first) that browsers and assistant
/// widgets play, then marks the clip ready. Runs on the job queue, one at a time, never inside a request.
/// </summary>
public sealed class ClipTranscodeJob(
	ArchiveDbContext db,
	ClipStorage storage,
	Ffmpeg ffmpeg,
	SettingsService settingsService,
	TimeProvider time,
	ILogger<ClipTranscodeJob> logger)
	: IJobHandler
{
	public const string Type = "clip.transcode";

	public sealed record Payload(Guid ClipId);

	public async Task RunAsync(JobContext job, CancellationToken cancellationToken)
	{
		var clipId = job.GetPayload<Payload>().ClipId;
		var clip = await db.Clips.SingleOrDefaultAsync(c => c.Id == clipId, cancellationToken);
		if (clip is null || clip.Status != ClipStatus.Received || clip.Path is null)
		{
			// Deleted since, or already done by an earlier attempt.
			return;
		}

		var settings = await settingsService.GetAsync(cancellationToken);
		var source = storage.Resolve(clip.Path);
		if (!File.Exists(source))
		{
			clip.Status = ClipStatus.Failed;
			clip.Error = "The uploaded audio is missing.";
			await db.SaveChangesAsync(cancellationToken);
			return;
		}

		var relativeOutput = ClipStorage.RelativePath(clip.UserId, clip.Id, ".m4a");
		var output = storage.Resolve(relativeOutput);
		var temporary = output + ".tmp";
		try
		{
			await ffmpeg.TranscodeToM4aAsync(source, temporary, settings.ClipAudioKbps, cancellationToken);
			File.Move(temporary, output, overwrite: true);
		}
		catch (Exception ex) when (ex is not OperationCanceledException)
		{
			File.Delete(temporary);
			if (job.Attempt >= settings.JobMaxAttempts)
			{
				// The queue sets the job aside after this; the clip says so too, so tools stop waiting for it.
				clip.Status = ClipStatus.Failed;
				clip.Error = "The audio could not be converted.";
				await db.SaveChangesAsync(CancellationToken.None);
			}

			throw;
		}

		clip.DurationMs = OggSpeexInfo.DurationMs(source);
		clip.Path = relativeOutput;
		clip.ByteCount = new FileInfo(output).Length;
		clip.Status = ClipStatus.Ready;
		clip.ReadyAt = time.GetUtcNow();
		clip.Error = null;
		try
		{
			await db.SaveChangesAsync(cancellationToken);
		}
		catch (DbUpdateConcurrencyException)
		{
			// Deleted while it was converting (a wipe, or its conversation deleted): leave nothing behind.
			File.Delete(output);
			File.Delete(source);
			return;
		}

		File.Delete(source);
		logger.LogInformation("Clip {ClipId} is ready ({Bytes} bytes, {DurationMs} ms).", clip.Id, clip.ByteCount, clip.DurationMs);
	}
}

/// <summary>
/// Runs the system ffmpeg. Ubuntu 22.04's ffmpeg 4.4 decodes Speex only through libspeex, while ffmpeg 5.0 and
/// later (Homebrew) has a native decoder and may lack libspeex, so the decoder is chosen from what this ffmpeg
/// lists. Always <c>-ac 1</c>: the native decoder leaves the channel layout unset and the AAC encoder refuses it.
/// </summary>
public sealed class Ffmpeg(IOptions<PebbleAudioOptions> options, ILogger<Ffmpeg> logger)
{
	private static readonly TimeSpan Timeout = TimeSpan.FromMinutes(10);

	private readonly SemaphoreSlim _probe = new(1, 1);
	private bool? _hasLibspeex;

	private string Binary => options.Value.FfmpegPath is { Length: > 0 } path ? path : "ffmpeg";

	public async Task TranscodeToM4aAsync(string input, string output, int kbps, CancellationToken cancellationToken)
	{
		var arguments = new List<string> { "-nostdin", "-hide_banner", "-v", "error", "-y" };
		if (await HasLibspeexAsync(cancellationToken))
		{
			arguments.AddRange(["-c:a", "libspeex"]);
		}

		arguments.AddRange(
		[
			"-i", input,
			"-map", "0:a:0", "-map_metadata", "-1", "-vn", "-ac", "1",
			"-c:a", "aac", "-b:a", $"{kbps}k",
			"-movflags", "+faststart", "-f", "ipod",
			output,
		]);

		var (exitCode, error) = await RunAsync(arguments, cancellationToken);
		if (exitCode != 0)
		{
			throw new InvalidOperationException($"ffmpeg exited with {exitCode}: {error.Trim()}");
		}
	}

	private async Task<bool> HasLibspeexAsync(CancellationToken cancellationToken)
	{
		if (_hasLibspeex is { } known)
		{
			return known;
		}

		await _probe.WaitAsync(cancellationToken);
		try
		{
			if (_hasLibspeex is null)
			{
				var (exitCode, listing) = await RunAsync(["-hide_banner", "-decoders"], cancellationToken, readOutput: true);
				_hasLibspeex = exitCode == 0 && listing.Contains(" libspeex ", StringComparison.Ordinal);
				logger.LogInformation("ffmpeg decodes Speex with {Decoder}.", _hasLibspeex.Value ? "libspeex" : "its native decoder");
			}

			return _hasLibspeex.Value;
		}
		finally
		{
			_probe.Release();
		}
	}

	private async Task<(int ExitCode, string Text)> RunAsync(
		IReadOnlyList<string> arguments,
		CancellationToken cancellationToken,
		bool readOutput = false)
	{
		var start = new ProcessStartInfo(Binary)
		{
			RedirectStandardError = true,
			RedirectStandardOutput = true,
			UseShellExecute = false,
		};
		foreach (var argument in arguments)
		{
			start.ArgumentList.Add(argument);
		}

		using var process = Process.Start(start) ?? throw new InvalidOperationException("ffmpeg did not start.");
		try
		{
			// Transcoding shares one vCPU with Postgres and the web server.
			process.PriorityClass = ProcessPriorityClass.BelowNormal;
		}
		catch (Exception ex) when (ex is InvalidOperationException or System.ComponentModel.Win32Exception or PlatformNotSupportedException)
		{
		}

		using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
		timeout.CancelAfter(Timeout);
		var output = process.StandardOutput.ReadToEndAsync(timeout.Token);
		var error = process.StandardError.ReadToEndAsync(timeout.Token);
		try
		{
			await process.WaitForExitAsync(timeout.Token);
		}
		catch (OperationCanceledException)
		{
			process.Kill(entireProcessTree: true);
			if (cancellationToken.IsCancellationRequested)
			{
				throw;
			}

			throw new TimeoutException($"ffmpeg ran longer than {Timeout.TotalMinutes} minutes.");
		}

		var standardOutput = await output;
		var standardError = await error;
		return (process.ExitCode, readOutput ? standardOutput : standardError);
	}
}
