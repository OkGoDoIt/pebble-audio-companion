using System.Globalization;
using System.Security.Claims;
using Microsoft.EntityFrameworkCore;
using PebbleAudio.Server.Data;
using PebbleAudio.Server.Mcp;
using PebbleAudio.Server.Sync;

namespace PebbleAudio.Server.Pages.View;

/// <summary>
/// What the viewer shows, read through <see cref="ArchiveReader"/>'s queries so it is the signed-in person's own
/// archive and never anything outside the sharing scope: the same window the assistants see. Nothing here is
/// logged as an assistant read; the person is reading their own archive.
/// </summary>
public sealed class ViewerReader(ArchiveReader archive, PhoneRequestService requests, ClipStorage storage)
{
	/// <summary>How many days the home page lists.</summary>
	public const int HomeDays = 60;

	/// <summary>Turns at most this long, said within this many seconds of each other, read as one run.</summary>
	private const int RunInLength = 24;

	private const int RunInGapSeconds = 20;

	public ViewerLinks Links => archive.Links;

	public Task<ToolCall> BeginAsync(ClaimsPrincipal user, CancellationToken cancellationToken) => archive.BeginAsync(user, cancellationToken);

	public IQueryable<Conversation> Conversations(ToolCall call) => archive.Conversations(call);

	// Home

	public async Task<HomeView> HomeAsync(ToolCall call, CancellationToken cancellationToken)
	{
		var conversationDays = await archive.Conversations(call).Select(c => c.DayKey).Distinct().OrderByDescending(d => d).Take(HomeDays).ToListAsync(cancellationToken);
		var recapDays = await archive.Recaps(call).Select(r => r.DayKey).OrderByDescending(d => d).Take(HomeDays).ToListAsync(cancellationToken);
		var days = conversationDays.Concat(recapDays).Distinct().OrderDescending().Take(HomeDays).ToList();
		return new HomeView(await DayRowsAsync(call, days, cancellationToken), ScopeLine(call.Scope));
	}

	/// <summary>Rows for these days, in the order given.</summary>
	public async Task<List<DayRow>> DayRowsAsync(ToolCall call, IReadOnlyList<DateOnly> days, CancellationToken cancellationToken)
	{
		if (days.Count == 0)
		{
			return [];
		}

		var recaps = await archive.Recaps(call).Where(r => days.Contains(r.DayKey)).ToDictionaryAsync(r => r.DayKey, cancellationToken);
		var coverage = await archive.Coverage(call).Where(c => days.Contains(c.DayKey)).ToDictionaryAsync(c => c.DayKey, cancellationToken);
		var conversations = (await archive.Conversations(call).Where(c => days.Contains(c.DayKey)).OrderBy(c => c.StartedAt).ToListAsync(cancellationToken))
			.ToLookup(c => c.DayKey);
		return
		[
			.. days.Select(day =>
			{
				recaps.TryGetValue(day, out var recap);
				coverage.TryGetValue(day, out var covered);
				var list = conversations[day].ToList();
				var talk = list.Where(c => c.ContentKind == ContentKind.Conversation).ToList();
				var recordedMs = covered?.RecordedMs ?? list.Sum(c => c.RecordedMs);
				var lostSeconds = covered is not null ? covered.MissingMs / 1000.0 : list.Sum(c => GapSeconds(c, GapKind.Lost));
				var headline = ArchiveReader.Blank(recap?.Headline);
				var line = ArchiveReader.Blank(recap?.LineSummary);
				if (headline is null)
				{
					// No recap yet: the day's titles stand in, so the row still leads with words.
					var titles = talk.Select(c => ArchiveReader.Blank(c.Title)).OfType<string>().Take(3).ToList();
					headline = titles.Count == 0 ? null : ViewText.List(titles);
				}

				var meta = new List<string> { ViewText.Count(talk.Count, "conversation", "conversations") };
				if (recordedMs > 0)
				{
					meta.Add($"{ViewText.Duration(recordedMs / 1000.0)} recorded");
				}

				return new DayRow(
					day,
					archive.Links.Day(day),
					day.ToString("ddd", ViewText.English),
					day.Day.ToString(CultureInfo.InvariantCulture),
					day.ToString("MMMM yyyy", ViewText.English),
					headline,
					line,
					string.Join(" · ", meta),
					lostSeconds >= 1 ? ViewText.Missing(lostSeconds) : null);
			}),
		];
	}

	// A conversation

	public async Task<ConversationView?> ConversationAsync(ToolCall call, string id, int? t, CancellationToken cancellationToken)
	{
		var c = await archive.Conversations(call).SingleOrDefaultAsync(x => x.Id == id, cancellationToken);
		if (c is null)
		{
			return null;
		}

		var transcript = await archive.Transcripts(call).SingleOrDefaultAsync(x => x.ConversationId == id, cancellationToken);
		var zone = LogicalDays.Zone(c.TimeZone);
		var live = c.State == ConversationState.Live;
		var start = Days.Local(c.StartedAt, zone);
		var endAt = c.EndedAt ?? (live ? call.Now : c.StartedAt.AddMilliseconds(c.RecordedMs));
		var end = Days.Local(endAt, zone);
		var duration = Math.Max(1, (int)Math.Round((endAt - c.StartedAt).TotalSeconds));
		var moment = t is { } seconds ? Math.Clamp(seconds, 0, duration) : (int?)null;

		var items = transcript?.Items.OrderBy(i => i.At).ToList() ?? [];
		var speakers = Speakers(c, items);
		var (lanes, laneOf) = Lanes(speakers);
		var marks = Marks(c, items, duration);
		var rows = Rows(c, items, zone, duration, laneOf, speakers, marks);
		int? cited = moment is { } m && rows.Count > 0 ? Math.Max(0, rows.FindLastIndex(r => r.S <= m)) : null;

		var turns = new List<(int Lane, int S, int E)>();
		foreach (var bit in rows.SelectMany(r => r.Bits))
		{
			turns.Add((bit.Lane, bit.S, bit.E));
		}

		var followUps = await archive.FollowUps(call).Where(f => f.SourceConversationId == id).OrderBy(f => f.SourceAt ?? f.CreatedAt).ToListAsync(cancellationToken);
		var notes = await archive.Notes(call).Where(n => n.ConversationId == id).OrderBy(n => n.CreatedAt).ToListAsync(cancellationToken);
		var sameDay = await archive.Conversations(call)
			.Where(x => x.DayKey == c.DayKey && x.Id != id)
			.OrderBy(x => x.StartedAt)
			.Select(x => new { x.Id, x.Title, x.StartedAt, x.TimeZone })
			.ToListAsync(cancellationToken);
		var before = sameDay.LastOrDefault(x => x.StartedAt < c.StartedAt);
		var after = sameDay.FirstOrDefault(x => x.StartedAt >= c.StartedAt);
		NeighborView? Neighbor(string? nid, string? title, DateTimeOffset at, string tz) => nid is null
			? null
			: new NeighborView(ArchiveReader.Blank(title) ?? ViewText.NotSummarized, archive.Links.Conversation(nid), ViewText.Clock(Days.Local(at, LogicalDays.Zone(tz))));

		var lostSeconds = GapSeconds(c, GapKind.Lost);
		var named = speakers.Where(s => s.Named).Select(s => s.Name).Distinct().ToList();
		var title = ArchiveReader.Blank(c.Title);
		var firstWords = ViewText.FirstWords(items.FirstOrDefault(i => i.Kind == TranscriptItemKind.Turn)?.Text);
		var span = ClipSpan(duration, moment ?? 0, (int)call.Settings.ClipMaxDuration.TotalSeconds);

		return new ConversationView(
			c,
			title ?? firstWords ?? ViewText.NotSummarized,
			title is not null,
			ArchiveReader.Blank(c.Summary),
			c.Tags,
			c.DayKey,
			ViewText.Weekday(c.DayKey),
			archive.Links.Day(c.DayKey),
			ArchiveReader.ZoneName(c.TimeZone),
			start,
			end,
			duration,
			ViewText.ShortDate(c.DayKey, call.Today),
			ViewText.Range(start, end),
			live ? $"{ViewText.Duration(duration)} so far" : ViewText.Duration(duration),
			lostSeconds >= 1 ? ViewText.Missing(lostSeconds) : null,
			ViewText.People(named, speakers.Count(s => !s.Named)),
			lanes,
			turns,
			marks,
			rows,
			cited,
			moment,
			transcript is not null,
			live,
			await archive.FollowUpsAsync(call, followUps, cancellationToken),
			[.. notes.Select(n => archive.Note(call, n, c))],
			before is null ? null : Neighbor(before.Id, before.Title, before.StartedAt, before.TimeZone),
			after is null ? null : Neighbor(after.Id, after.Title, after.StartedAt, after.TimeZone),
			await ClipStateAsync(call, c, span.From, span.To, moment ?? span.From, cancellationToken));
	}

	private sealed record Speaker(string Label, string Name, bool Named, double Seconds, int Rank);

	/// <summary>Everyone who speaks, most talk first. A label the app has not matched keeps the transcriber's number.</summary>
	private static List<Speaker> Speakers(Conversation c, IReadOnlyList<TranscriptItem> items)
	{
		var names = c.People.Where(p => !string.IsNullOrWhiteSpace(p.Label)).GroupBy(p => p.Label).ToDictionary(g => g.Key, g => ArchiveReader.Blank(g.First().Name));
		var talk = new Dictionary<string, double>(StringComparer.Ordinal);
		var order = new List<string>();
		for (var i = 0; i < items.Count; i++)
		{
			var item = items[i];
			if (item.Kind != TranscriptItemKind.Turn)
			{
				continue;
			}

			var label = ArchiveReader.Blank(item.Speaker) ?? "?";
			if (!talk.ContainsKey(label))
			{
				order.Add(label);
				talk[label] = 0;
			}

			talk[label] += (TurnEnd(items, i) - item.At).TotalSeconds;
			if (!names.TryGetValue(label, out var known) || known is null)
			{
				names[label] = ArchiveReader.Blank(item.Name);
			}
		}

		foreach (var person in c.People.Where(p => !talk.ContainsKey(p.Label)))
		{
			order.Add(person.Label);
			talk[person.Label] = 0;
		}

		return
		[
			.. order
				.OrderByDescending(label => talk[label])
				.ThenBy(label => order.IndexOf(label))
				.Select((label, rank) =>
				{
					var name = names.GetValueOrDefault(label);
					return new Speaker(label, name ?? (label == "?" ? "Someone" : $"Speaker {label}"), name is not null, talk[label], rank);
				}),
		];
	}

	/// <summary>
	/// One lane per voice that carries the conversation (a tenth of the talk or more, up to four); any others share
	/// one lane, "Other voices". Returns the lanes and which lane each speaker label is drawn in.
	/// </summary>
	private static (List<LaneView> Lanes, Dictionary<string, int> LaneOf) Lanes(IReadOnlyList<Speaker> speakers)
	{
		var spoken = speakers.Where(s => s.Seconds > 0).ToList();
		var laneOf = new Dictionary<string, int>(StringComparer.Ordinal);
		if (spoken.Count == 0)
		{
			return ([new LaneView(0, "Speech", "s0")], laneOf);
		}

		var total = spoken.Sum(s => s.Seconds);
		var major = spoken.Where((s, i) => i == 0 || s.Seconds >= total * 0.1).Take(4).ToList();
		if (spoken.Count - major.Count == 1 && major.Count < 4)
		{
			// One more voice gets its own lane rather than a lane called "Other voices".
			major = spoken;
		}

		// Named voices take the strip's three hues in order; an unnamed one stays gray, as the app shows a speaker
		// it has not matched, and so does the lane of other voices.
		var hue = 0;
		var lanes = major.Select((s, i) => new LaneView(i, s.Name, s.Named ? (hue++) switch
		{
			0 => "s0",
			1 => "s1",
			_ => "s2",
		} : "s3")).ToList();
		for (var i = 0; i < major.Count; i++)
		{
			laneOf[major[i].Label] = i;
		}

		if (spoken.Count > major.Count)
		{
			lanes.Add(new LaneView(lanes.Count, "Other voices", "s3"));
			foreach (var s in spoken.Skip(major.Count))
			{
				laneOf[s.Label] = lanes.Count - 1;
			}
		}

		return (lanes, laneOf);
	}

	/// <summary>Quiet, paused, lost, and masked stretches, drawn to scale and never mixed up.</summary>
	private static List<MarkView> Marks(Conversation c, IReadOnlyList<TranscriptItem> items, int duration)
	{
		var marks = new List<MarkView>();
		foreach (var gap in c.Gaps.OrderBy(g => g.StartedAt))
		{
			var (s, e) = (Clamp(gap.StartedAt, c, duration), Clamp(gap.EndedAt, c, duration));
			if (e <= s)
			{
				continue;
			}

			var seconds = (gap.EndedAt - gap.StartedAt).TotalSeconds;
			marks.Add(gap.Kind switch
			{
				GapKind.Quiet when gap.Reason == "watchPause" => new MarkView("paused", s, e, $"Paused · {ViewText.Duration(seconds, seconds: true)} · {ViewText.WatchSavingPower}"),
				GapKind.Quiet => new MarkView("quiet", s, e, $"Quiet · {ViewText.Duration(seconds, seconds: true)}"),
				GapKind.Lost => new MarkView("lost", s, e, string.Join(" · ", new[] { ViewText.Missing(seconds), ViewText.LossCause(gap.Origin) }.OfType<string>())),
			});
		}

		foreach (var item in items.Where(i => i.Kind == TranscriptItemKind.Masked && i.EndAt is not null))
		{
			var (s, e) = (Clamp(item.At, c, duration), Clamp(item.EndAt!.Value, c, duration));
			if (e > s)
			{
				marks.Add(new MarkView("masked", s, e, $"{ViewText.Capitalized(ArchiveReader.Blank(item.Descriptor) ?? "music")} · {ViewText.Duration((item.EndAt.Value - item.At).TotalSeconds, seconds: true)}"));
			}
		}

		return [.. marks.OrderBy(m => m.S)];
	}

	private static List<RowView> Rows(
		Conversation c,
		IReadOnlyList<TranscriptItem> items,
		TimeZoneInfo zone,
		int duration,
		IReadOnlyDictionary<string, int> laneOf,
		IReadOnlyList<Speaker> speakers,
		IReadOnlyList<MarkView> marks)
	{
		var whoOf = speakers.ToDictionary(s => s.Label, s => s.Name);
		var rows = new List<RowView>();
		string? lastMinute = null;
		RowView Row(RowKind kind, DateTimeOffset at, int s, int e, IReadOnlyList<BitView> bits, string? text, string? detail)
		{
			var local = Days.Local(at, zone);
			var minute = ViewText.ShortClock(local);
			var isNew = minute != lastMinute;
			lastMinute = minute;
			return new RowView(kind, s, e, minute, isNew, $"Play from {local.ToString("h:mm:ss tt", ViewText.English)}", bits, text, detail);
		}

		for (var i = 0; i < items.Count; i++)
		{
			var item = items[i];
			var s = Clamp(item.At, c, duration);
			switch (item.Kind)
			{
				case TranscriptItemKind.Turn:
				{
					var bits = new List<BitView> { Bit(items, i) };
					// Short back-and-forth folds into one run-in line, so a run of "Okay" doesn't take a row each.
					while (IsShort(item) && i + 1 < items.Count && IsShort(items[i + 1]) &&
						(items[i + 1].At - TurnEnd(items, i)).TotalSeconds <= RunInGapSeconds)
					{
						i++;
						bits.Add(Bit(items, i));
					}

					rows.Add(Row(bits.Count > 1 ? RowKind.Run : RowKind.Turn, item.At, s, bits[^1].E, bits, null, null));
					break;
				}

				case TranscriptItemKind.Quiet or TranscriptItemKind.Lost or TranscriptItemKind.Masked:
				{
					var e = item.EndAt is { } end ? Clamp(end, c, duration) : s;
					// The conversation's own gaps know why (the watch's power-save pause, where a loss happened).
					var mark = marks.Where(m => m.S < Math.Max(e, s + 1) && m.E > s)
						.OrderByDescending(m => Math.Min(m.E, e) - Math.Max(m.S, s))
						.FirstOrDefault(m => item.Kind switch
						{
							TranscriptItemKind.Quiet => m.Kind is "quiet" or "paused",
							TranscriptItemKind.Lost => m.Kind == "lost",
							_ => m.Kind == "masked",
						});
					var seconds = item.EndAt is { } stop ? (stop - item.At).TotalSeconds : 0;
					var (kind, text) = item.Kind switch
					{
						TranscriptItemKind.Quiet when mark?.Kind == "paused" => (RowKind.Paused, mark.Label),
						TranscriptItemKind.Quiet => (RowKind.Quiet, $"Quiet · {ViewText.Duration(seconds, seconds: true)}"),
						TranscriptItemKind.Lost => (RowKind.Lost, string.Join(" · ", new[] { ViewText.Missing(seconds), ViewText.LossCause(ArchiveReader.Blank(item.Origin) ?? MarkOrigin(c, item)) }.OfType<string>())),
						_ => (RowKind.Masked, $"{ViewText.Capitalized(ArchiveReader.Blank(item.Descriptor) ?? "music")} · {ViewText.Duration(seconds, seconds: true)}"),
					};
					rows.Add(Row(kind, item.At, s, Math.Max(e, s), [], text, null));
					break;
				}
			}
		}

		return rows;

		BitView Bit(IReadOnlyList<TranscriptItem> list, int index)
		{
			var turn = list[index];
			var label = ArchiveReader.Blank(turn.Speaker) ?? "?";
			var s = Clamp(turn.At, c, duration);
			var e = Math.Max(s + 1, Clamp(TurnEnd(list, index), c, duration));
			return new BitView(
				laneOf.GetValueOrDefault(label),
				ArchiveReader.Blank(turn.Name) ?? whoOf.GetValueOrDefault(label) ?? $"Speaker {label}",
				turn.Text?.Trim() ?? "",
				s,
				e,
				turn.Confidence is < 0.6);
		}
	}

	private static string? MarkOrigin(Conversation c, TranscriptItem item) =>
		c.Gaps.Where(g => g.Kind == GapKind.Lost && g.StartedAt < (item.EndAt ?? item.At.AddSeconds(1)) && g.EndedAt > item.At)
			.Select(g => g.Origin)
			.FirstOrDefault();

	private static bool IsShort(TranscriptItem item) =>
		item.Kind == TranscriptItemKind.Turn && (item.Text?.Trim().Length ?? 0) is > 0 and <= RunInLength;

	/// <summary>When a turn ends: its own end, else where the next item starts, else a few seconds on.</summary>
	private static DateTimeOffset TurnEnd(IReadOnlyList<TranscriptItem> items, int index)
	{
		var item = items[index];
		if (item.EndAt is { } end && end > item.At)
		{
			return end;
		}

		var next = index + 1 < items.Count ? items[index + 1].At : item.At.AddSeconds(5);
		return next > item.At ? (next - item.At > TimeSpan.FromSeconds(30) ? item.At.AddSeconds(30) : next) : item.At.AddSeconds(2);
	}

	private static int Clamp(DateTimeOffset at, Conversation c, int duration) => Math.Clamp(Days.Offset(at, c.StartedAt), 0, duration);

	private static double GapSeconds(Conversation c, GapKind kind) =>
		c.Gaps.Where(g => g.Kind == kind).Sum(g => Math.Max(0, (g.EndedAt - g.StartedAt).TotalSeconds));

	// Clips

	/// <summary>
	/// The clip window around a moment, in seconds from the start: the whole conversation when it fits in the
	/// longest clip, else that length on a grid of half of it, so moments near each other share one clip. The first
	/// window is the one get_audio asks for by default.
	/// </summary>
	public static (int From, int To) ClipSpan(int duration, int t, int maxSeconds)
	{
		if (duration <= maxSeconds)
		{
			return (0, duration);
		}

		var step = Math.Max(60, maxSeconds / 2);
		var from = Math.Max(0, t - 60) / step * step;
		from = Math.Min(from, duration - maxSeconds);
		return (from, from + maxSeconds);
	}

	/// <summary>
	/// Where the clip for a window stands without asking the phone for anything: a ready clip that holds the
	/// moment, else the request for exactly this window, else whether one may be asked for.
	/// </summary>
	public async Task<ClipState> ClipStateAsync(ToolCall call, Conversation c, int from, int to, int moment, CancellationToken cancellationToken)
	{
		var db = archive.Db;
		var userId = call.UserId;
		var at = c.StartedAt.AddSeconds(moment);
		var ready = await db.Clips.AsNoTracking()
			.Where(x => x.UserId == userId && x.ConversationId == c.Id && x.Status == ClipStatus.Ready && x.StartAt <= at && x.EndAt > at)
			.OrderByDescending(x => x.ReadyAt)
			.ToListAsync(cancellationToken);
		foreach (var clip in ready.Where(x => x.Path is not null && File.Exists(storage.Resolve(x.Path))))
		{
			if (await requests.GetClipRequestAsync(userId, clip.RequestId, cancellationToken) is { Outcome: ClipOutcome.Ready } result)
			{
				return State(result, c, from, to);
			}
		}

		var (startAt, endAt) = Instants(c, from, to);
		var asked = await db.Clips.AsNoTracking()
			.Where(x => x.UserId == userId && x.ConversationId == c.Id && x.StartAt == startAt && x.EndAt == endAt)
			.OrderByDescending(x => x.CreatedAt)
			.FirstOrDefaultAsync(cancellationToken);
		if (asked is not null && await requests.GetClipRequestAsync(userId, asked.RequestId, cancellationToken) is { } described &&
			described.Outcome is not ClipOutcome.Ready and not ClipOutcome.NotDelivered)
		{
			return State(described, c, from, to);
		}

		if (c.ExpiredOnPhoneAt is not null)
		{
			return Empty("unavailable", "gone", from, to);
		}

		var preferences = await requests.GetPreferencesAsync(userId, cancellationToken);
		return !preferences.Clips ? Empty("notAllowed", null, from, to) : Empty("none", asked is null ? null : "notDelivered", from, to);
	}

	/// <summary>Asks the phone for the window (or finds the clip already on its way).</summary>
	public async Task<ClipState> RequestClipAsync(ToolCall call, Conversation c, int from, int to, CancellationToken cancellationToken)
	{
		var (startAt, endAt) = Instants(c, from, to);
		var result = await requests.RequestClipAsync(call.UserId, c.Id, startAt, endAt, cancellationToken);
		return State(result, c, from, to);
	}

	public async Task<ClipState?> ClipRequestAsync(ToolCall call, Conversation c, Guid requestId, CancellationToken cancellationToken)
	{
		var result = await requests.GetClipRequestAsync(call.UserId, requestId, cancellationToken);
		return result is null || result.ConversationId != c.Id ? null : State(result, c, 0, 0);
	}

	/// <summary>The window as the instants the clip machinery stores (whole milliseconds, inside the conversation).</summary>
	private static (DateTimeOffset Start, DateTimeOffset End) Instants(Conversation c, int from, int to)
	{
		static DateTimeOffset Ms(DateTimeOffset at) => DateTimeOffset.FromUnixTimeMilliseconds(at.ToUnixTimeMilliseconds());
		var start = Ms(c.StartedAt.AddSeconds(from));
		var end = Ms(c.StartedAt.AddSeconds(to));
		if (c.EndedAt is { } ended && end > ended)
		{
			end = Ms(ended);
		}

		return (start, end);
	}

	private static ClipState Empty(string status, string? reason, int from, int to) =>
		new(status, reason, null, null, null, from, to, null, null, [], null, null);

	private static ClipState State(ClipRequestResult r, Conversation c, int from, int to)
	{
		int? T(DateTimeOffset? at) => at is { } x ? Days.Offset(x, c.StartedAt) : null;
		var (status, reason) = r.Outcome switch
		{
			ClipOutcome.Ready => ("ready", (string?)null),
			ClipOutcome.Waiting => ("requested", null),
			ClipOutcome.NotAllowed => ("notAllowed", null),
			ClipOutcome.Unavailable => ("unavailable", "gone"),
			ClipOutcome.Failed => ("unavailable", "failed"),
			ClipOutcome.NotDelivered => ("unavailable", "notDelivered"),
			ClipOutcome.NotFound => ("unavailable", "notFound"),
		};
		return new ClipState(
			status,
			reason,
			r.RequestId,
			r.Link?.Url,
			r.Link?.ExpiresAt,
			T(r.StartAt) ?? from,
			T(r.EndAt) ?? to,
			T(r.CoveredStartAt),
			T(r.CoveredEndAt),
			[.. r.Gaps.Select(g => new[] { Days.Offset(g.StartedAt, c.StartedAt), Days.Offset(g.EndedAt, c.StartedAt) })],
			r.DurationMs,
			r.WaitingUntil);
	}

	// A day

	public async Task<DayView> DayAsync(ToolCall call, DateOnly day, CancellationToken cancellationToken)
	{
		var weekUrl = archive.Links.Week(day.AddDays(-(int)day.DayOfWeek));
		var place = ViewText.Place(call.Scope.TimeZoneId);
		if (!call.Scope.HoldsDay(day))
		{
			return Bare(DayState.OutsideScope);
		}

		var recap = await archive.Recaps(call).SingleOrDefaultAsync(r => r.DayKey == day, cancellationToken);
		var coverage = await archive.Coverage(call).SingleOrDefaultAsync(r => r.DayKey == day, cancellationToken);
		var conversations = await archive.Conversations(call).Where(c => c.DayKey == day).OrderBy(c => c.StartedAt).ToListAsync(cancellationToken);
		var (previous, next) = await NeighborDaysAsync(call, day, cancellationToken);
		if (recap is null && coverage is null && conversations.Count == 0)
		{
			return Bare(DayState.Nothing) with { Previous = previous, Next = next };
		}

		var zoneId = coverage?.TimeZone ?? recap?.TimeZone ?? conversations.FirstOrDefault()?.TimeZone ?? call.Scope.TimeZoneId;
		var zone = LogicalDays.Zone(zoneId);
		var ids = conversations.Select(c => c.Id).ToList();
		var followUps = await archive.FollowUps(call).Where(f => f.SourceConversationId != null && ids.Contains(f.SourceConversationId)).OrderBy(f => f.SourceAt ?? f.CreatedAt).ToListAsync(cancellationToken);
		var followUpsBy = followUps.ToLookup(f => f.SourceConversationId!);

		// Coverage is only what the window holds: a day that starts before it is drawn from where it starts.
		var spans = (coverage?.Spans ?? [])
			.Select(s => new CoverageSpan { Kind = s.Kind, StartedAt = s.StartedAt < call.From ? call.From : s.StartedAt, EndedAt = s.EndedAt })
			.Where(s => s.EndedAt > s.StartedAt)
			.OrderBy(s => s.StartedAt)
			.ToList();

		var cards = conversations.Select(c => Card(call, c, followUpsBy[c.Id])).ToList();
		var items = new List<TimelineItem>();
		DateTimeOffset? lastEnd = spans.Count > 0 ? spans[0].StartedAt : null;
		for (var i = 0; i < conversations.Count; i++)
		{
			var c = conversations[i];
			if (lastEnd is { } from && Stretch(spans, from, c.StartedAt, i == 0 ? Edge.Until : Edge.None, Days.Local(c.StartedAt, zone)) is { } between)
			{
				items.Add(new TimelineItem(null, between));
			}

			items.Add(new TimelineItem(cards[i], null));
			lastEnd = End(c, call);
		}

		if (spans.Count > 0 && lastEnd is { } tail && Stretch(spans, tail, spans[^1].EndedAt, Edge.After, Days.Local(tail, zone)) is { } after)
		{
			items.Add(new TimelineItem(null, after));
		}

		return new DayView(
			day,
			DayState.Found,
			ViewText.Weekday(day),
			ViewText.LongDate(day),
			ViewText.Place(zoneId),
			ArchiveReader.Blank(recap?.Headline),
			ArchiveReader.Blank(recap?.LineSummary),
			ArchiveReader.Blank(recap?.Text),
			Strip(call, zone, spans, conversations),
			Totals(coverage, spans, conversations, call),
			items,
			followUps.Count,
			followUps.Count(f => ArchiveReader.FollowUpStatus(f, call.Now) == "open"),
			previous,
			next,
			weekUrl,
			ScopeLine(call.Scope));

		DayView Bare(DayState state) => new(
			day, state, ViewText.Weekday(day), ViewText.LongDate(day), place, null, null, null, null, [], [], 0, 0, null, null, weekUrl, ScopeLine(call.Scope));
	}

	private async Task<(DateOnly? Previous, DateOnly? Next)> NeighborDaysAsync(ToolCall call, DateOnly day, CancellationToken cancellationToken)
	{
		var earlier = await archive.Conversations(call).Where(c => c.DayKey < day).MaxAsync(c => (DateOnly?)c.DayKey, cancellationToken);
		var later = await archive.Conversations(call).Where(c => c.DayKey > day).MinAsync(c => (DateOnly?)c.DayKey, cancellationToken);
		return (earlier, later);
	}

	private static DateTimeOffset End(Conversation c, ToolCall call) =>
		c.EndedAt ?? (c.State == ConversationState.Live ? call.Now : c.StartedAt.AddMilliseconds(c.RecordedMs));

	private CardView Card(ToolCall call, Conversation c, IEnumerable<FollowUp> followUps)
	{
		var zone = LogicalDays.Zone(c.TimeZone);
		var start = Days.Local(c.StartedAt, zone);
		var end = Days.Local(End(c, call), zone);
		var seconds = (end - start).TotalSeconds;
		var lost = GapSeconds(c, GapKind.Lost);
		var title = ArchiveReader.Blank(c.Title);
		var noConversation = c.ContentKind == ContentKind.NoConversation;
		var shownTitle = title ?? (noConversation ? ViewText.Capitalized(ArchiveReader.Blank(c.ContentDescriptor) ?? "No conversation") : ViewText.NotSummarized);
		return new CardView(
			c.Id,
			archive.Links.Conversation(c.Id),
			shownTitle,
			title is not null,
			noConversation ? null : ArchiveReader.Blank(c.Summary),
			ViewText.ShortClock(start),
			$"{ViewText.Range(start, end)} · {ViewText.Duration(seconds)}",
			lost >= 1 ? ViewText.Missing(lost) : null,
			noConversation ? [] : c.Tags,
			noConversation ? [] : [.. c.People.Select(p => ArchiveReader.Blank(p.Name)).OfType<string>().Distinct()],
			noConversation || seconds < 180,
			[.. followUps.Take(3).Select(f => (f.Text, f.Done || f.ArchivedAt is not null))]);
	}

	private enum Edge
	{
		None,
		Until,
		After,
	}

	/// <summary>
	/// What the time between two items was, from the day's coverage; null for under five minutes. At the day's ends
	/// it reads as the app's edges do: "Quiet until 9:12 AM", "Nothing recorded after 4:20 PM".
	/// </summary>
	private static StretchView? Stretch(IReadOnlyList<CoverageSpan> spans, DateTimeOffset from, DateTimeOffset to, Edge edge, DateTimeOffset edgeTime)
	{
		if (to - from < TimeSpan.FromMinutes(5))
		{
			return null;
		}

		var sums = new Dictionary<CoverageKind, double>();
		foreach (var span in spans)
		{
			var overlap = (Min(span.EndedAt, to) - Max(span.StartedAt, from)).TotalSeconds;
			if (overlap > 0)
			{
				sums[span.Kind] = sums.GetValueOrDefault(span.Kind) + overlap;
			}
		}

		var missing = sums.GetValueOrDefault(CoverageKind.Missing);
		var kinds = sums.Where(k => k.Key != CoverageKind.Missing && k.Value >= 60).OrderByDescending(k => k.Value).ToList();
		if (kinds.Count == 0)
		{
			return missing >= 1 ? new StretchView("missing", "Audio missing", null, null, null, (int)(missing / 60)) : null;
		}

		static string Name(CoverageKind kind) => kind switch
		{
			CoverageKind.Recorded => "No conversation",
			CoverageKind.Quiet => "Quiet",
			CoverageKind.Missing => "Audio missing",
			CoverageKind.Paused => "Paused",
			CoverageKind.Off => "Not recording",
		};

		static string Bar(CoverageKind kind) => kind switch
		{
			CoverageKind.Recorded => "background",
			CoverageKind.Quiet => "quiet",
			CoverageKind.Missing => "missing",
			CoverageKind.Paused => "paused",
			CoverageKind.Off => "off",
		};

		var (first, firstSeconds) = (kinds[0].Key, kinds[0].Value);
		if (edge != Edge.None)
		{
			// Nobody was listening through a pause or with the watch off, so that edge is not "quiet".
			var listening = first is CoverageKind.Quiet or CoverageKind.Recorded;
			var word = edge == Edge.Until ? "until" : "after";
			var edgeName = listening ? $"Quiet {word} {ViewText.Clock(edgeTime)}" : $"Nothing recorded {word} {ViewText.Clock(edgeTime)}";
			return new StretchView(listening ? "quiet" : Bar(first), edgeName, null, null, missing >= 1 ? ViewText.Missing(missing) : null, (int)Math.Round((to - from).TotalMinutes));
		}

		string? rest = null;
		if (kinds.Count > 1 && kinds[1].Value >= 300)
		{
			rest = $"{Name(kinds[1].Key).ToLowerInvariant()} {ViewText.Duration(kinds[1].Value)}";
		}

		var label = rest is null ? $"{Name(first)} · {ViewText.Duration(firstSeconds)}" : $"{Name(first)} {ViewText.Duration(firstSeconds)}";
		var total = (int)Math.Round((to - from).TotalMinutes);
		return new StretchView(
			Bar(first),
			label,
			rest,
			first == CoverageKind.Paused ? "you paused capture" : null,
			missing >= 1 ? ViewText.Missing(missing) : null,
			total);
	}

	private DayStripView? Strip(ToolCall call, TimeZoneInfo zone, IReadOnlyList<CoverageSpan> spans, IReadOnlyList<Conversation> conversations)
	{
		var starts = spans.Select(s => s.StartedAt).Concat(conversations.Select(c => c.StartedAt)).ToList();
		var ends = spans.Select(s => s.EndedAt).Concat(conversations.Select(c => End(c, call))).ToList();
		if (starts.Count == 0)
		{
			return null;
		}

		var first = Days.Local(starts.Min(), zone);
		var last = Days.Local(ends.Max(), zone);
		var axisStart = new DateTimeOffset(first.Year, first.Month, first.Day, first.Hour, 0, 0, first.Offset);
		var axisEnd = new DateTimeOffset(last.Year, last.Month, last.Day, last.Hour, 0, 0, last.Offset);
		if (axisEnd < last)
		{
			axisEnd = axisEnd.AddHours(1);
		}

		if (axisEnd - axisStart < TimeSpan.FromHours(2))
		{
			axisEnd = axisStart.AddHours(2);
		}

		var total = (axisEnd - axisStart).TotalSeconds;
		double Pct(DateTimeOffset at) => Math.Round(Math.Clamp((at - axisStart).TotalSeconds / total, 0, 1) * 100, 3);
		string Range(DateTimeOffset a, DateTimeOffset b) => ViewText.Range(Days.Local(a, zone), Days.Local(b, zone));

		var pieces = spans.Select(s =>
		{
			var (kind, name) = s.Kind switch
			{
				CoverageKind.Recorded => ("recorded", "Recorded"),
				CoverageKind.Quiet => ("quiet", "Quiet"),
				CoverageKind.Missing => ("missing", "Audio missing"),
				CoverageKind.Paused => ("paused", "Paused"),
				CoverageKind.Off => ("off", "Not recording"),
			};
			return new StripPiece(kind, Pct(s.StartedAt), Math.Round(Pct(s.EndedAt) - Pct(s.StartedAt), 3), $"{name} · {Range(s.StartedAt, s.EndedAt)}", null);
		}).ToList();
		var blocks = conversations.Select(c => new StripPiece(
			c.ContentKind == ContentKind.NoConversation ? "background" : "talk",
			Pct(c.StartedAt),
			Math.Round(Pct(End(c, call)) - Pct(c.StartedAt), 3),
			$"{ArchiveReader.Blank(c.Title) ?? ViewText.NotSummarized} · {Range(c.StartedAt, End(c, call))}",
			archive.Links.Conversation(c.Id))).ToList();

		var hours = (axisEnd - axisStart).TotalHours;
		var step = hours switch
		{
			<= 4 => 1,
			<= 8 => 2,
			<= 14 => 3,
			_ => 4,
		};
		var ticks = new List<StripTick>();
		for (var at = axisStart; at <= axisEnd; at = at.AddHours(step))
		{
			ticks.Add(new StripTick(Pct(at), at.ToString(at.Minute == 0 ? "h tt" : "h:mm tt", ViewText.English)));
		}

		var talk = conversations.Where(c => c.ContentKind == ContentKind.Conversation).ToList();
		var lost = spans.Where(s => s.Kind == CoverageKind.Missing).Sum(s => (s.EndedAt - s.StartedAt).TotalSeconds);
		var label = $"{ViewText.Count(talk.Count, "conversation", "conversations")} from {ViewText.Clock(first)} to {ViewText.Clock(last)}" +
			(lost >= 1 ? $", {ViewText.Missing(lost)}" : "");
		return new DayStripView(pieces, blocks, ticks, label);
	}

	private static List<TotalView> Totals(CoverageDay? coverage, IReadOnlyList<CoverageSpan> spans, IReadOnlyList<Conversation> conversations, ToolCall call)
	{
		double Sum(CoverageKind kind) => spans.Where(s => s.Kind == kind).Sum(s => (s.EndedAt - s.StartedAt).TotalSeconds);
		var talk = conversations.Where(c => c.ContentKind == ContentKind.Conversation).Sum(c => (End(c, call) - c.StartedAt).TotalSeconds);
		var quiet = coverage is not null ? coverage.QuietMs / 1000.0 : conversations.Sum(c => GapSeconds(c, GapKind.Quiet));
		var lost = coverage is not null ? coverage.MissingMs / 1000.0 : conversations.Sum(c => GapSeconds(c, GapKind.Lost));
		var totals = new List<TotalView>();
		void Add(string kind, string name, double seconds)
		{
			if (seconds >= 1)
			{
				totals.Add(new TotalView(kind, name, ViewText.Duration(seconds, seconds: kind == "missing")));
			}
		}

		Add("talk", "Conversations", talk);
		Add("quiet", "Quiet", quiet);
		Add("paused", "Paused", Sum(CoverageKind.Paused));
		Add("missing", "Audio missing", lost);
		Add("off", "Not recording", Sum(CoverageKind.Off));
		return totals;
	}

	// A brief

	public async Task<BriefView> BriefAsync(ToolCall call, BriefKind kind, DateOnly start, CancellationToken cancellationToken)
	{
		var end = kind switch
		{
			BriefKind.Week => start.AddDays(6),
			BriefKind.Month => start.AddMonths(1).AddDays(-1),
		};
		var inScope = call.Scope.HoldsDay(end);
		var brief = inScope
			? await archive.Briefs(call).Where(b => b.Kind == kind && b.StartDay == start).OrderByDescending(b => b.Version).FirstOrDefaultAsync(cancellationToken)
			: null;
		if (brief is not null)
		{
			end = brief.EndDay;
		}

		var days = new List<DateOnly>();
		if (inScope)
		{
			var conversationDays = await archive.Conversations(call).Where(c => c.DayKey >= start && c.DayKey <= end).Select(c => c.DayKey).Distinct().ToListAsync(cancellationToken);
			var recapDays = await archive.Recaps(call).Where(r => r.DayKey >= start && r.DayKey <= end).Select(r => r.DayKey).ToListAsync(cancellationToken);
			days = [.. conversationDays.Concat(recapDays).Distinct().Order()];
		}

		var (title, range, previous, next) = kind switch
		{
			BriefKind.Week => (
				$"Week of {start.ToString(start.Year == call.Today.Year ? "MMMM d" : "MMMM d, yyyy", ViewText.English)}",
				start.Month == end.Month
					? $"{start.ToString("MMMM d", ViewText.English)} – {end.Day}, {end.Year}"
					: $"{start.ToString("MMM d", ViewText.English)} – {end.ToString("MMM d, yyyy", ViewText.English)}",
				archive.Links.Week(start.AddDays(-7)),
				archive.Links.Week(start.AddDays(7))),
			BriefKind.Month => (
				start.ToString("MMMM yyyy", ViewText.English),
				$"{start.ToString("MMMM d", ViewText.English)} – {end.Day}, {end.Year}",
				archive.Links.Month(start.AddMonths(-1)),
				archive.Links.Month(start.AddMonths(1))),
		};

		return new BriefView(
			kind,
			start,
			end,
			title,
			range,
			inScope,
			brief is not null,
			ArchiveReader.Blank(brief?.Headline),
			ArchiveReader.Blank(brief?.LineSummary),
			ArchiveReader.Blank(brief?.Text),
			await DayRowsAsync(call, days, cancellationToken),
			previous,
			next,
			ScopeLine(call.Scope));
	}

	/// <summary>The week a day falls in, as the phone keyed it: a brief's own first day when one holds it, else the Sunday before.</summary>
	public async Task<DateOnly> WeekStartAsync(ToolCall call, DateOnly day, CancellationToken cancellationToken) =>
		await archive.Briefs(call)
			.Where(b => b.Kind == BriefKind.Week && b.StartDay <= day && b.EndDay >= day)
			.Select(b => (DateOnly?)b.StartDay)
			.FirstOrDefaultAsync(cancellationToken)
		?? day.AddDays(-(int)day.DayOfWeek);

	/// <summary>One line on what the phone shares, when it does not share everything.</summary>
	public static string? ScopeLine(AccountScope scope) => scope.Kind switch
	{
		SharingScopeKind.All => null,
		SharingScopeKind.LastDays => scope.Days == 1 ? "Your phone shares the last day." : $"Your phone shares the last {scope.Days} days.",
		SharingScopeKind.Since => scope.FromDay is { } day ? $"Your phone shares what was recorded from {ViewText.LongDate(day)} on." : null,
	};

	private static DateTimeOffset Min(DateTimeOffset a, DateTimeOffset b) => a < b ? a : b;

	private static DateTimeOffset Max(DateTimeOffset a, DateTimeOffset b) => a > b ? a : b;
}
