using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using PebbleAudio.Server.Data;

namespace PebbleAudio.Server.Tests;

/// <summary>
/// Quiet and missing audio on the web read the way the phone's transcript shows them: one calm row per real
/// interruption, in the app's words, never a row per gap record. The case is the shape that made the viewer unreadable
/// on 2026-10-21 (synthetic numbers): the watch dropping a fraction of a second every two seconds for minutes on end.
/// </summary>
public sealed partial class ViewerTests
{
	private static readonly DateTimeOffset Noon = new(2026, 10, 12, 12, 0, 0, ArchiveFixture.Offset);

	private static JsonObject Row(DateTimeOffset start, DateTimeOffset end, string kind, string label, long? missingMs = null, string? cause = null, bool shown = true)
	{
		var row = ArchiveFixture.Gap(start, end, kind, origin: kind == "lost" ? "watch" : null);
		row["label"] = label;
		if (missingMs is { } ms)
		{
			row["missingMs"] = ms;
		}

		if (cause is not null)
		{
			row["cause"] = cause;
		}

		if (!shown)
		{
			row["shown"] = false;
		}

		return row;
	}

	private static JsonObject ItemOf(JsonObject row)
	{
		var item = ArchiveFixture.Marker(
			DateTimeOffset.Parse(row["startedAt"]!.GetValue<string>()), DateTimeOffset.Parse(row["endedAt"]!.GetValue<string>()),
			row["kind"]!.GetValue<string>(), row["origin"]?.GetValue<string>());
		foreach (var key in new[] { "label", "cause", "missingMs" })
		{
			if (row[key] is { } value)
			{
				item[key] = value.DeepClone();
			}
		}

		return item;
	}

	private static JsonObject[] Talk(DateTimeOffset start, int minutes, Func<DateTimeOffset, bool> quiet) =>
	[
		.. Enumerable.Range(0, minutes * 3)
			.Select(i => start.AddSeconds(i * 20 + 4))
			.Where(at => !quiet(at))
			.Select((at, i) => ArchiveFixture.Turn(at, i % 2 == 0 ? "1" : "2", i % 2 == 0 ? "Alex" : "Sam", $"Line {i} about the garden plot.", 0.9)),
	];

	[Fact]
	public async Task A_choppy_conversation_reads_as_one_calm_row_per_interruption_on_the_web_and_in_the_tools()
	{
		var (phone, fixture) = await ArchiveFixture.SeedAsync(factory);
		using var _ = phone;
		var day = DateOnly.FromDateTime(Noon.DateTime);

		// What a phone with the gap change sends: the transcript screen's rows. Brief drops over fourteen minutes are one
		// row that says what it lost; a 3-second one counts but gets no line; a real 40-second hole is its own row.
		var spread = Row(Noon.AddMilliseconds(1_500), Noon.AddMilliseconds(897_700), "lost", "audio interrupted for 1 min over 14 min", 91_300, "watch buffer filled while disconnected");
		var quiet = Row(Noon.AddMinutes(3), Noon.AddSeconds(366), "quiet", "quiet for 3 min");
		var brief = Row(Noon.AddMinutes(20), Noon.AddSeconds(1203), "lost", "audio interrupted for 3 sec", 3_000, "watch buffer filled while disconnected", shown: false);
		var hole = Row(Noon.AddMinutes(30), Noon.AddSeconds(1840), "lost", "audio interrupted for 40 sec", 40_000, "connection was interrupted");
		var conversation = ArchiveFixture.Conversation(day, Noon, Noon.AddMinutes(44), "Planning the garden plot", "Alex and Sam plan the beds.", ["garden"], [ArchiveFixture.Speaker("1", null, "Alex"), ArchiveFixture.Speaker("2", null, "Sam")], [spread, quiet, brief, hole], 40);
		conversation["missingMs"] = 134_300;
		bool Silent(DateTimeOffset at) => (at >= Noon.AddMinutes(3) && at < Noon.AddSeconds(366)) || (at >= Noon.AddMinutes(30) && at < Noon.AddSeconds(1840));
		var items = Talk(Noon, 44, Silent).Concat([ItemOf(spread), ItemOf(quiet), ItemOf(hole)]).OrderBy(i => i["at"]!.GetValue<string>(), StringComparer.Ordinal).ToArray();
		Assert.Equal(0, (await phone.BatchAsync(
			ArchiveFixture.Item("conversation", "conv-choppy", conversation),
			ArchiveFixture.Item("transcript", "conv-choppy", ArchiveFixture.Transcript("conv-choppy", items)))).GetProperty("rejected").GetArrayLength());

		using var browser = await SignedInAsync(phone.UserId);
		var page = await PageAsync(browser, "/c/conv-choppy");
		// Two amber rows, in the app's words, and the quiet as a calm separator.
		Assert.Equal(2, Regex.Count(page, "class=\"row lost"));
		Assert.Contains("audio interrupted for 1 min over 14 min (watch buffer filled while disconnected)", page, StringComparison.Ordinal);
		Assert.Contains("audio interrupted for 40 sec (connection was interrupted)", page, StringComparison.Ordinal);
		Assert.DoesNotContain("<p class=\"gap\">audio interrupted for 3 sec", page, StringComparison.Ordinal);
		Assert.Equal(1, Regex.Count(page, "class=\"row quiet"));
		Assert.Contains("quiet for 3 min", page, StringComparison.Ordinal);
		// The header counts what is missing, as the phone's History card does: not the fourteen minutes the drops span.
		Assert.Contains("44 min · <span class=\"loss\">2 min missing</span>", Regex.Replace(page, "<span class=\"sep\"> · </span>", " · "), StringComparison.Ordinal);

		// The strip marks every interruption, the brief one too, like the app's scrubber ticks: a hole to scale, and the
		// spread drops as a tick where they start, not fourteen minutes of amber. The quiet covers its stretch. A new
		// phone's clips place their own audio, so no holes; the strip says the header's total.
		var model = JsonDocument.Parse(Model().Match(page).Groups["json"].Value).RootElement;
		var marks = model.GetProperty("gaps").EnumerateArray().Select(g => (g.GetProperty("k").GetString(), g.GetProperty("s").GetInt32(), g.GetProperty("e").GetInt32())).ToList();
		Assert.Equal([("lost", 1, 2), ("quiet", 180, 366), ("lost", 1200, 1203), ("lost", 1800, 1840)], marks);
		Assert.Empty(model.GetProperty("holes").EnumerateArray());
		Assert.Equal(134, model.GetProperty("missing").GetDouble());

		// The tools read the same rows: the interruptions with a line of their own and the quiet, the loss in minutes,
		// and the transcript's markers in the app's words.
		await using var mcp = await ArchiveFixture.ConnectAsync(factory, phone.UserId, TokenAccess.Read);
		var got = await ArchiveFixture.CallAsync(mcp, "get_conversation", new() { ["id"] = "conv-choppy", ["include"] = "both" });
		Assert.Equal(2.2, got.GetProperty("lostMinutes").GetDouble());
		Assert.Equal(3.1, got.GetProperty("quietMinutes").GetDouble());
		var gaps = got.GetProperty("gaps").EnumerateArray().ToList();
		Assert.Equal(["lost", "quiet", "lost"], gaps.Select(g => g.GetProperty("kind").GetString()));
		Assert.Equal((14.9, 1.5), (gaps[0].GetProperty("minutes").GetDouble(), gaps[0].GetProperty("missingMinutes").GetDouble()));
		Assert.Equal("audio interrupted for 1 min over 14 min (watch buffer filled while disconnected)", gaps[0].GetProperty("label").GetString());
		var markers = got.GetProperty("transcript").GetProperty("items").EnumerateArray().Where(i => i.GetProperty("kind").GetString() != "turn").ToList();
		Assert.Equal(["audio interrupted for 1 min over 14 min (watch buffer filled while disconnected)", "quiet for 3 min", "audio interrupted for 40 sec (connection was interrupted)"], markers.Select(m => m.GetProperty("label").GetString()));
		var fetched = (await ArchiveFixture.CallAsync(mcp, "fetch", new() { ["id"] = "conv-choppy" })).GetProperty("text").GetString()!;
		Assert.Contains("[12:00–12:14] (audio interrupted for 1 min over 14 min: watch buffer filled while disconnected)", fetched, StringComparison.Ordinal);
		Assert.Contains("[12:03–12:06] (quiet for 3 min)", fetched, StringComparison.Ordinal);
		Assert.DoesNotContain("lost audio", fetched, StringComparison.Ordinal);
	}

	[Fact]
	public async Task An_older_phones_one_second_gaps_read_as_the_app_would_show_them_until_it_sends_again()
	{
		var (phone, _) = await ArchiveFixture.SeedAsync(factory);
		using var __ = phone;
		var day = DateOnly.FromDateTime(Noon.DateTime);

		// What a phone before the gap change sent: one lost gap, and one transcript marker, per record — 300 drops of
		// 0.4 seconds every 2 seconds for ten minutes — and a hole between two pieces that no record explains.
		var drops = Enumerable.Range(0, 300).Select(i => ArchiveFixture.Gap(Noon.AddMilliseconds(i * 2_000), Noon.AddMilliseconds(i * 2_000 + 400), "lost", origin: "watch")).ToArray();
		var unexplained = ArchiveFixture.Gap(Noon.AddMinutes(12), Noon.AddMinutes(26), "lost", origin: "unknown");
		var conversation = ArchiveFixture.Conversation(day, Noon, Noon.AddMinutes(30), "Watering the beds", null, [], [ArchiveFixture.Speaker("1", null, "Alex")], [.. drops, unexplained], 14);
		var items = Talk(Noon, 30, at => at >= Noon.AddMinutes(12) && at < Noon.AddMinutes(26))
			.Concat(drops.Select(g => ArchiveFixture.Marker(DateTimeOffset.Parse(g["startedAt"]!.GetValue<string>()), DateTimeOffset.Parse(g["endedAt"]!.GetValue<string>()), "lost", "watch")))
			.OrderBy(i => i["at"]!.GetValue<string>(), StringComparer.Ordinal)
			.ToArray();
		Assert.Equal(0, (await phone.BatchAsync(
			ArchiveFixture.Item("conversation", "conv-legacy-choppy", conversation),
			ArchiveFixture.Item("transcript", "conv-legacy-choppy", ArchiveFixture.Transcript("conv-legacy-choppy", items)))).GetProperty("rejected").GetArrayLength());

		using var browser = await SignedInAsync(phone.UserId);
		var page = await PageAsync(browser, "/c/conv-legacy-choppy");
		// One row, not three hundred, and the unexplained hole is not called missing (the app calls it not recording).
		Assert.Equal(1, Regex.Count(page, "class=\"row lost"));
		Assert.Contains("<p class=\"gap\">audio interrupted for 2 min over 9 min</p>", page, StringComparison.Ordinal);
		Assert.DoesNotContain("1 sec missing", page, StringComparison.Ordinal);
		Assert.Contains("<span class=\"loss\">2 min missing</span>", page, StringComparison.Ordinal);
		// Its records still place an old clip's audio on the clock, as they always did (at the strip's one-second
		// resolution, which a 0.4-second drop is under).
		var model = JsonDocument.Parse(Model().Match(page).Groups["json"].Value).RootElement;
		Assert.Equal([("lost", 720, 1560)], model.GetProperty("holes").EnumerateArray().Select(h => (h.GetProperty("k").GetString(), h.GetProperty("s").GetInt32(), h.GetProperty("e").GetInt32())));
	}
}
