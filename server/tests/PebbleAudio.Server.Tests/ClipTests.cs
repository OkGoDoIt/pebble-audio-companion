using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json.Nodes;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using PebbleAudio.Server.Data;
using PebbleAudio.Server.Jobs;
using PebbleAudio.Server.Sync;

namespace PebbleAudio.Server.Tests;

[Collection(ServerCollection.Name)]
public sealed class ClipTests(ArchiveServerFactory factory)
{
	private const long V = 1_791_999_175_292;

	[Fact]
	public async Task A_clip_request_reaches_the_phone_and_its_upload_is_queued_for_conversion()
	{
		var userId = await factory.CreateUserAsync();
		using var phone = await Phone.LinkAsync(factory, userId);
		var id = $"conv-seg-{Guid.NewGuid():N}";
		await phone.BatchAsync(Wire.Item("conversation", id, V, payload: Wire.Conversation("Interview with the landlord")));
		await phone.AllowAsync(clips: true, edits: false);

		await using var scope = factory.Services.CreateAsyncScope();
		var requests = scope.ServiceProvider.GetRequiredService<PhoneRequestService>();
		var db = scope.ServiceProvider.GetRequiredService<ArchiveDbContext>();
		var none = CancellationToken.None;

		var asked = await requests.RequestClipAsync(userId, id, Wire.Start.AddMinutes(1), Wire.Start.AddMinutes(3), none);
		Assert.Equal(ClipOutcome.Waiting, asked.Outcome);
		Assert.InRange(asked.WaitingUntil!.Value - DateTimeOffset.UtcNow, TimeSpan.FromHours(23), TimeSpan.FromHours(24));
		Assert.Null(asked.Link);
		// Asking again for the same span is the same request.
		Assert.Equal(asked.RequestId, (await requests.RequestClipAsync(userId, id, Wire.Start.AddMinutes(1), Wire.Start.AddMinutes(3), none)).RequestId);

		// A span is kept inside the conversation and to the longest clip (20 minutes by default).
		var capped = await requests.RequestClipAsync(userId, id, Wire.Start.AddHours(-1), Wire.Start.AddHours(2), none);
		Assert.Equal((Wire.Start, Wire.Start.AddMinutes(20)), (capped.StartAt!.Value, capped.EndAt!.Value));
		await Assert.ThrowsAsync<ArgumentOutOfRangeException>(() => requests.RequestClipAsync(userId, id, Wire.Start.AddHours(3), Wire.Start.AddHours(4), none));
		Assert.Equal(ClipOutcome.NotFound, (await requests.RequestClipAsync(userId, "conv-nowhere", Wire.Start, Wire.Start.AddMinutes(1), none)).Outcome);

		var pulled = (await phone.GetJsonAsync("/sync/requests")).GetProperty("requests").EnumerateArray().ToList();
		Assert.Equal(2, pulled.Count);
		var clipRequest = pulled.Single(r => r.GetProperty("id").GetString() == asked.RequestId.ToString());
		Assert.Equal("clip", clipRequest.GetProperty("kind").GetString());
		var payload = clipRequest.GetProperty("payload");
		Assert.Equal(id, payload.GetProperty("conversationId").GetString());
		Assert.Equal(Wire.T(Wire.Start.AddMinutes(1)), payload.GetProperty("startAt").GetString());
		Assert.Equal(Wire.T(Wire.Start.AddMinutes(3)), payload.GetProperty("endAt").GetString());
		Assert.Equal(1_200_000, payload.GetProperty("maxMs").GetInt64());

		// Uploads: the wrong type, something that is not Ogg, a request that does not exist, then the clip.
		var path = $"/sync/clips/{asked.RequestId}";
		var ogg = OggSpeexFile.FromFixture();
		var text = new StringContent("hello", Encoding.UTF8, "text/plain");
		Assert.Equal(HttpStatusCode.UnsupportedMediaType, (await phone.SendAsync(HttpMethod.Put, path, text)).StatusCode);
		Assert.Equal(HttpStatusCode.BadRequest, (await phone.SendAsync(HttpMethod.Put, path, SyncTests.Clip(Encoding.ASCII.GetBytes("not audio at all")))).StatusCode);
		Assert.Equal(HttpStatusCode.NotFound, (await phone.SendAsync(HttpMethod.Put, $"/sync/clips/{Guid.NewGuid()}", SyncTests.Clip(ogg))).StatusCode);
		var lost = $$"""[{"endedAt":"{{Wire.T(Wire.Start.AddMinutes(2.5))}}","startedAt":"{{Wire.T(Wire.Start.AddMinutes(2))}}"}]""";
		var stored = await phone.SendAsync(HttpMethod.Put, path, SyncTests.Clip(ogg, Wire.Start.AddMinutes(1), Wire.Start.AddMinutes(2.9), lost));
		Assert.Equal(HttpStatusCode.Created, stored.StatusCode);
		// A retried upload is answered the same and stores nothing twice.
		Assert.Equal(HttpStatusCode.Created, (await phone.SendAsync(HttpMethod.Put, path, SyncTests.Clip(ogg))).StatusCode);

		var clip = await db.Clips.AsNoTracking().SingleAsync(c => c.Id == asked.ClipId);
		Assert.Equal(ClipStatus.Received, clip.Status);
		Assert.Equal((Wire.Start.AddMinutes(1), Wire.Start.AddMinutes(2.9)), (clip.CoveredStartAt!.Value, clip.CoveredEndAt!.Value));
		Assert.Equal(Wire.Start.AddMinutes(2), Assert.Single(clip.Gaps).StartedAt);
		Assert.Equal(ogg.Length, clip.ByteCount);
		Assert.Equal(ogg, await File.ReadAllBytesAsync(Path.Combine(factory.ClipsPath, clip.Path!)));
		var job = await db.Jobs.AsNoTracking().SingleAsync(j => j.UserId == userId);
		Assert.Equal((ClipTranscodeJob.Type, JobState.Pending), (job.Type, job.State));
		Assert.Equal(PhoneRequestState.Done, (await db.Requests.AsNoTracking().SingleAsync(r => r.Id == asked.RequestId)).State);
		Assert.Equal(1, (await phone.GetJsonAsync("/sync/requests")).GetProperty("requests").GetArrayLength());
		// Being converted still reads as waiting.
		Assert.Equal(ClipOutcome.Waiting, (await requests.RequestClipAsync(userId, id, Wire.Start.AddMinutes(1), Wire.Start.AddMinutes(3), none)).Outcome);

		// The phone says it has no audio for the long one: that answer stands instead of asking again.
		var result = await phone.SendAsync(
			HttpMethod.Post,
			$"/sync/requests/{capped.RequestId}/result",
			Phone.Json(new JsonObject { ["status"] = "unavailable", ["detail"] = "No audio is stored for that span." }));
		Assert.Equal(HttpStatusCode.NoContent, result.StatusCode);
		var unavailable = await requests.RequestClipAsync(userId, id, Wire.Start.AddHours(-1), Wire.Start.AddHours(2), none);
		Assert.Equal((ClipOutcome.Unavailable, capped.RequestId), (unavailable.Outcome, unavailable.RequestId));
		Assert.Equal("No audio is stored for that span.", unavailable.Detail);
		Assert.Equal(0, (await phone.GetJsonAsync("/sync/requests")).GetProperty("requests").GetArrayLength());

		// Turning clips off on the phone removes every clip the server holds, the upload waiting for conversion included.
		var upload = Path.Combine(factory.ClipsPath, clip.Path!);
		await phone.AllowAsync(clips: false, edits: false);
		Assert.False(await db.Clips.AnyAsync(c => c.UserId == userId));
		Assert.False(await db.Requests.AnyAsync(r => r.UserId == userId && r.Kind == PhoneRequestKind.Clip));
		Assert.False(File.Exists(upload));

		// Not converted here; the ffmpeg test does that.
		await db.Jobs.Where(j => j.Id == job.Id).ExecuteDeleteAsync();
	}

	[FfmpegFact]
	public async Task An_uploaded_clip_is_converted_and_served_through_a_short_lived_link_with_ranges()
	{
		var userId = await factory.CreateUserAsync();
		using var phone = await Phone.LinkAsync(factory, userId);
		var id = $"conv-seg-{Guid.NewGuid():N}";
		await phone.BatchAsync(Wire.Item("conversation", id, V, payload: Wire.Conversation("Piano lesson")));
		await phone.AllowAsync(clips: true, edits: false);

		await using var scope = factory.Services.CreateAsyncScope();
		var requests = scope.ServiceProvider.GetRequiredService<PhoneRequestService>();
		var db = scope.ServiceProvider.GetRequiredService<ArchiveDbContext>();
		var links = scope.ServiceProvider.GetRequiredService<ClipLinks>();
		var runner = factory.Services.GetRequiredService<JobRunner>();
		var none = CancellationToken.None;

		var asked = await requests.RequestClipAsync(userId, id, Wire.Start, Wire.Start.AddSeconds(3), none);
		var upload = await phone.SendAsync(HttpMethod.Put, $"/sync/clips/{asked.RequestId}", SyncTests.Clip(OggSpeexFile.FromFixture(seconds: 3)));
		Assert.Equal(HttpStatusCode.Created, upload.StatusCode);
		for (var i = 0; i < 10 && await runner.RunNextAsync(none); i++)
		{
		}

		var clip = await db.Clips.AsNoTracking().SingleAsync(c => c.Id == asked.ClipId);
		Assert.True(clip.Status == ClipStatus.Ready, $"The clip is {clip.Status}: {clip.Error} {(await db.Jobs.AsNoTracking().Where(j => j.UserId == userId).Select(j => j.Error).FirstOrDefaultAsync())}");
		Assert.Equal(3_000, clip.DurationMs);
		Assert.EndsWith(".m4a", clip.Path);
		Assert.False(File.Exists(Path.ChangeExtension(Path.Combine(factory.ClipsPath, clip.Path!), ".ogg")), "The upload is removed once converted.");

		var ready = await requests.RequestClipAsync(userId, id, Wire.Start, Wire.Start.AddSeconds(3), none);
		Assert.Equal(ClipOutcome.Ready, ready.Outcome);
		Assert.StartsWith($"{ArchiveServerFactory.PublicOrigin}/clips/{clip.Id:N}.m4a?exp=", ready.Link!.Url);
		Assert.InRange(ready.Link.ExpiresAt - DateTimeOffset.UtcNow, TimeSpan.FromMinutes(59), TimeSpan.FromMinutes(60));

		using var browser = factory.CreateClient();
		var url = new Uri(ready.Link.Url).PathAndQuery;
		var whole = await browser.GetAsync(url);
		Assert.Equal(HttpStatusCode.OK, whole.StatusCode);
		Assert.Equal("audio/mp4", whole.Content.Headers.ContentType?.MediaType);
		Assert.Contains("bytes", whole.Headers.AcceptRanges);
		var bytes = await whole.Content.ReadAsByteArrayAsync();
		Assert.Equal(clip.ByteCount, bytes.Length);
		Assert.Equal("ftyp", Encoding.ASCII.GetString(bytes, 4, 4));

		var range = new HttpRequestMessage(HttpMethod.Get, url);
		range.Headers.Range = new RangeHeaderValue(0, 99);
		var partial = await browser.SendAsync(range);
		Assert.Equal(HttpStatusCode.PartialContent, partial.StatusCode);
		Assert.Equal(100, (await partial.Content.ReadAsByteArrayAsync()).Length);
		Assert.Equal(bytes.Length, partial.Content.Headers.ContentRange?.Length);

		// Only the link as minted, for that clip, before it expires.
		Assert.Equal(HttpStatusCode.Forbidden, (await browser.GetAsync(url[..^4] + "AAAA")).StatusCode);
		Assert.Equal(HttpStatusCode.Forbidden, (await browser.GetAsync(url.Replace(clip.Id.ToString("N"), Guid.NewGuid().ToString("N")))).StatusCode);
		Assert.Equal(HttpStatusCode.Forbidden, (await browser.GetAsync($"/clips/{clip.Id:N}.m4a")).StatusCode);
		var expired = links.Create(clip.Id, DateTimeOffset.UtcNow.AddMinutes(-1));
		Assert.Equal(HttpStatusCode.Forbidden, (await browser.GetAsync(new Uri(expired.Url).PathAndQuery)).StatusCode);

		// Past the keep time (a week by default) the clip goes: its link stops working, and asking again asks the phone.
		await db.Clips.Where(c => c.Id == clip.Id).ExecuteUpdateAsync(s => s.SetProperty(c => c.ReadyAt, DateTimeOffset.UtcNow.AddDays(-8)));
		Assert.True(await scope.ServiceProvider.GetRequiredService<ClipRetention>().RemoveExpiredAsync(DateTimeOffset.UtcNow, none) >= 1);
		Assert.False(await db.Clips.AnyAsync(c => c.Id == clip.Id));
		Assert.False(File.Exists(Path.Combine(factory.ClipsPath, clip.Path!)));
		Assert.Equal(HttpStatusCode.NotFound, (await browser.GetAsync(url)).StatusCode);
		var again = await requests.RequestClipAsync(userId, id, Wire.Start, Wire.Start.AddSeconds(3), none);
		Assert.Equal(ClipOutcome.Waiting, again.Outcome);
		Assert.NotEqual(asked.RequestId, again.RequestId);
	}
}
