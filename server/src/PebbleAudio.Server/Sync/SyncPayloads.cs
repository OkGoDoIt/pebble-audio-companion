using System.Text.Json;
using PebbleAudio.Server.Data;

namespace PebbleAudio.Server.Sync;

/// <summary>
/// Reads the §2 payloads into entities, exactly as the phone sends them (see the notes in sync-protocol.md on
/// what the phone actually puts in each field). A payload that cannot be read gives a reason the phone logs and
/// parks the item with; it never throws. Fields the phone may add later are ignored.
/// </summary>
internal static class SyncPayloads
{
	public static Parsed<SyncedRecord> Read(SyncKind kind, string id, JsonElement payload) => kind switch
	{
		SyncKind.Conversation => Map(Deserialize<ConversationPayload>(payload), p => Conversation(id, p)),
		SyncKind.Transcript => Map(Deserialize<TranscriptPayload>(payload), p => Transcript(id, p)),
		SyncKind.Recap => Map(Deserialize<RecapPayload>(payload), p => Recap(id, p)),
		SyncKind.Brief => Map(Deserialize<BriefPayload>(payload), p => Brief(id, p)),
		SyncKind.FollowUp => Map(Deserialize<FollowUpPayload>(payload), p => FollowUp(id, p)),
		SyncKind.Note => Map(Deserialize<NotePayload>(payload), p => Note(id, p)),
		SyncKind.Person => Map(Deserialize<PersonPayload>(payload), p => Person(id, p)),
		SyncKind.Coverage => Map(Deserialize<CoveragePayload>(payload), p => Coverage(id, p)),
		SyncKind.VoiceRevocation => Map(Deserialize<VoiceRevocation>(payload), p =>
			ArchiveVoiceRevocations.Valid(p) ? Parsed<VoiceRevocation>.Ok(new VoiceRevocation
			{ Id = id, OriginID = p.OriginID, Generation = p.Generation, Scope = p.Scope, TargetID = p.TargetID })
			: Parsed<VoiceRevocation>.Fail("payload: invalid voice revocation")),
	};

	private static Parsed<SyncedRecord> Map<TPayload, TEntity>(Parsed<TPayload> payload, Func<TPayload, Parsed<TEntity>> read)
		where TPayload : class
		where TEntity : SyncedRecord
	{
		if (payload.Value is null)
		{
			return Parsed<SyncedRecord>.Fail(payload.Error!);
		}

		var entity = read(payload.Value);
		return entity.Value is null ? Parsed<SyncedRecord>.Fail(entity.Error!) : Parsed<SyncedRecord>.Ok(entity.Value);
	}

	private static Parsed<T> Deserialize<T>(JsonElement payload)
		where T : class
	{
		if (payload.ValueKind != JsonValueKind.Object)
		{
			return Parsed<T>.Fail("payload: not an object");
		}

		try
		{
			return payload.Deserialize<T>(SyncJson.Options) is { } value
				? Parsed<T>.Ok(value)
				: Parsed<T>.Fail("payload: empty");
		}
		catch (JsonException ex)
		{
			var path = (ex.Path ?? "").TrimStart('$', '.');
			var detail = ex.Message.Contains("Path:", StringComparison.Ordinal) ? "has the wrong type" : ex.Message;
			return Parsed<T>.Fail(path.Length > 0 ? $"payload: {path} {detail}" : $"payload: {detail}");
		}
	}

	// §2.1

	private static Parsed<Conversation> Conversation(string id, ConversationPayload p)
	{
		if (p.StartedAt is not { } startedAt)
		{
			return Missing<Conversation>("startedAt");
		}

		if (string.IsNullOrWhiteSpace(p.TimeZone))
		{
			return Missing<Conversation>("timeZone");
		}

		if (!SyncJson.TryParseDay(p.DayKey, out var dayKey))
		{
			return Parsed<Conversation>.Fail(p.DayKey is null ? "payload: dayKey missing" : $"payload: dayKey '{p.DayKey}' is not a day");
		}

		if (!WireNames.TryParse(p.State, out ConversationState state))
		{
			return Unknown<Conversation>("state", p.State);
		}

		if (!WireNames.TryParse(p.ContentKind, out ContentKind contentKind))
		{
			return Unknown<Conversation>("contentKind", p.ContentKind);
		}

		if (p.Pieces is null)
		{
			return Missing<Conversation>("pieces");
		}

		var pieces = new List<ConversationPiece>(p.Pieces.Count);
		for (var i = 0; i < p.Pieces.Count; i++)
		{
			var piece = p.Pieces[i];
			if (piece is null || string.IsNullOrEmpty(piece.SegmentId))
			{
				return Missing<Conversation>($"pieces[{i}].segmentId");
			}

			// A piece that is a whole segment carries startMediaMs 0 (the phone's documented form).
			if (piece.StartMediaMs is not { } startMediaMs)
			{
				return Missing<Conversation>($"pieces[{i}].startMediaMs");
			}

			if (piece.StartedAt is not { } pieceStart)
			{
				return Missing<Conversation>($"pieces[{i}].startedAt");
			}

			pieces.Add(new ConversationPiece
			{
				Ordinal = piece.Ordinal ?? i,
				SegmentId = piece.SegmentId,
				StartMediaMs = startMediaMs,
				EndMediaMs = piece.EndMediaMs,
				StartedAt = pieceStart,
				EndedAt = piece.EndedAt,
			});
		}

		var gaps = new List<ConversationGap>();
		for (var i = 0; i < (p.Gaps?.Count ?? 0); i++)
		{
			var gap = p.Gaps![i];
			if (gap?.StartedAt is not { } gapStart || gap.EndedAt is not { } gapEnd)
			{
				return Missing<Conversation>($"gaps[{i}].startedAt or endedAt");
			}

			if (!WireNames.TryParse(gap.Kind, out GapKind gapKind))
			{
				return Unknown<Conversation>($"gaps[{i}].kind", gap.Kind);
			}

			var causes = new List<GapCause>();
			foreach (var cause in gap.Causes ?? [])
			{
				if (cause is null || string.IsNullOrEmpty(cause.Code))
				{
					return Missing<Conversation>($"gaps[{i}].causes[].code");
				}

				causes.Add(new GapCause { Code = cause.Code, Text = cause.Text ?? "", Ms = Math.Max(0, cause.Ms ?? 0), Count = Math.Max(0, cause.Count ?? 0) });
			}

			gaps.Add(new ConversationGap
			{
				StartedAt = gapStart,
				EndedAt = gapEnd,
				Kind = gapKind,
				// The phone sends watch, link, or unknown for a loss, and nothing for quiet.
				Origin = gapKind == GapKind.Lost ? gap.Origin ?? "unknown" : gap.Origin,
				Reason = gap.Reason,
				// The rest is how the phone's transcript shows the row (sync-protocol.md §2.1); a phone before the gap
				// change sends none of it.
				MissingMs = gap.MissingMs is { } ms ? Math.Max(0, ms) : null,
				Label = gap.Label,
				Cause = gap.Cause,
				Causes = causes,
				Shown = gap.Shown ?? (gap.Label is null ? null : true),
			});
		}

		var people = new List<ConversationSpeaker>();
		foreach (var speaker in p.People ?? [])
		{
			if (speaker is null || string.IsNullOrEmpty(speaker.Label))
			{
				return Missing<Conversation>("people[].label");
			}

			if (speaker.VoiceEvidence is { } evidence && (evidence.Count > 256 || !evidence.All(ArchiveVoiceRevocations.Valid)
				|| evidence.Count > 0 && (speaker.PersonId is null || speaker.Name is null)))
			{
				return Parsed<Conversation>.Fail("payload: invalid people voice evidence");
			}
			people.Add(new ConversationSpeaker { Label = speaker.Label, PersonId = speaker.PersonId, Name = speaker.Name,
				VoiceEvidence = speaker.VoiceEvidence ?? [] });
		}

		return Parsed<Conversation>.Ok(new Conversation
		{
			Id = id,
			StartedAt = startedAt,
			EndedAt = p.EndedAt,
			TimeZone = p.TimeZone,
			DayKey = dayKey,
			State = state,
			StartReason = p.StartReason,
			Provisional = p.Provisional ?? false,
			Title = p.Title,
			Summary = p.Summary,
			Tags = [.. (p.Tags ?? []).OfType<string>()],
			TitleEditedByUser = p.TitleEditedByUser ?? false,
			IsFinal = p.IsFinal ?? false,
			AnnotationProvider = p.AnnotationProvider,
			AnnotationModel = p.AnnotationModel,
			ContentKind = contentKind,
			ContentDescriptor = p.ContentDescriptor,
			MostlyQuiet = p.MostlyQuiet ?? false,
			HasMissingAudio = p.HasMissingAudio ?? false,
			RecordedMs = p.RecordedMs ?? 0,
			MissingMs = p.MissingMs is { } missing ? Math.Max(0, missing) : null,
			Pieces = pieces,
			People = people,
			Gaps = gaps,
		});
	}

	// §2.2

	private static Parsed<Transcript> Transcript(string id, TranscriptPayload p)
	{
		if (p.ConversationId is { } conversationId && conversationId != id)
		{
			return Parsed<Transcript>.Fail("payload: conversationId is not the item's id");
		}

		if (p.Text is null)
		{
			return Missing<Transcript>("text");
		}

		var items = new List<TranscriptItem>();
		for (var i = 0; i < (p.Items?.Count ?? 0); i++)
		{
			var item = p.Items![i];
			if (item is null || !WireNames.TryParse(item.Kind, out TranscriptItemKind itemKind))
			{
				return Unknown<Transcript>($"items[{i}].kind", item?.Kind);
			}

			if (item.At is not { } at)
			{
				return Missing<Transcript>($"items[{i}].at");
			}

			items.Add(new TranscriptItem
			{
				Kind = itemKind,
				At = at,
				EndAt = item.EndAt,
				Speaker = item.Speaker,
				Name = item.Name,
				Text = item.Text,
				Confidence = item.Confidence,
				Origin = item.Origin,
				Descriptor = item.Descriptor,
				Label = item.Label,
				Cause = item.Cause,
				MissingMs = item.MissingMs is { } ms ? Math.Max(0, ms) : null,
				Reason = item.Reason,
			});
		}

		var anchored = new HashSet<int>();
		foreach (var anchor in p.SpeakerRanges ?? [])
		{
			if (!TranscriptSpeakerPatch.Valid(anchor) || anchor.ItemIndex is not { } index
				|| index < 0 || index >= items.Count || !anchored.Add(index)
				|| items[index].Kind != TranscriptItemKind.Turn || items[index].At != anchor.At
				|| items[index].EndAt != anchor.EndAt || items[index].Name != anchor.Name)
			{
				return Parsed<Transcript>.Fail("payload: invalid speakerRanges anchor");
			}
			items[index].SegmentId = anchor.SegmentId;
			items[index].StartMediaMs = anchor.StartMediaMs;
			items[index].EndMediaMs = anchor.EndMediaMs;
			items[index].PersonId = anchor.PersonId;
			items[index].IdentityResolved = true;
			items[index].VoiceEvidence = anchor.VoiceEvidence ?? [];
		}

		return Parsed<Transcript>.Ok(new Transcript
		{
			ConversationId = id,
			SourceHash = p.SourceHash,
			Provider = p.Provider,
			Model = p.Model,
			// The phone sends null today: it does not know the language yet.
			Language = p.Language,
			CharCount = p.CharCount ?? p.Text.Length,
			Text = p.Text,
			Items = items,
		});
	}

	// §2.3

	private static Parsed<Recap> Recap(string id, RecapPayload p)
	{
		if (!SyncJson.TryParseDay(id, out var day))
		{
			return Parsed<Recap>.Fail($"id: '{id}' is not a day");
		}

		if (p.DayKey is { } dayKey && dayKey != id)
		{
			return Parsed<Recap>.Fail("payload: dayKey is not the item's id");
		}

		return Parsed<Recap>.Ok(new Recap
		{
			DayKey = day,
			TimeZone = p.TimeZone ?? "",
			Headline = p.Headline,
			LineSummary = p.LineSummary,
			ShortText = p.ShortText,
			Text = p.Text,
			ConversationIds = [.. (p.ConversationIds ?? []).OfType<string>()],
			Provider = p.Provider,
			Model = p.Model,
		});
	}

	// §2.4

	private static Parsed<Brief> Brief(string id, BriefPayload p)
	{
		if (p.PeriodKey is { } periodKey && periodKey != id)
		{
			return Parsed<Brief>.Fail("payload: periodKey is not the item's id");
		}

		if (!WireNames.TryParse(p.Kind, out BriefKind kind))
		{
			return Unknown<Brief>("kind", p.Kind);
		}

		if (!SyncJson.TryParseDay(p.StartDay, out var startDay) || !SyncJson.TryParseDay(p.EndDay, out var endDay))
		{
			return Missing<Brief>("startDay or endDay");
		}

		return Parsed<Brief>.Ok(new Brief
		{
			PeriodKey = id,
			Kind = kind,
			StartDay = startDay,
			EndDay = endDay,
			Headline = p.Headline,
			LineSummary = p.LineSummary,
			Text = p.Text,
			Provider = p.Provider,
			Model = p.Model,
		});
	}

	// §2.5

	private static Parsed<FollowUp> FollowUp(string id, FollowUpPayload p)
	{
		if (p.Text is null)
		{
			return Missing<FollowUp>("text");
		}

		if (!WireNames.TryParse(p.Origin, out ContentOrigin origin))
		{
			return Unknown<FollowUp>("origin", p.Origin);
		}

		if (p.CreatedAt is not { } createdAt)
		{
			return Missing<FollowUp>("createdAt");
		}

		// A phone from before stages sends none: everything it has is a reminder.
		var stage = FollowUpStage.Reminder;
		if (p.Stage is not null && !WireNames.TryParse(p.Stage, out stage))
		{
			return Unknown<FollowUp>("stage", p.Stage);
		}

		return Parsed<FollowUp>.Ok(new FollowUp
		{
			Id = id,
			Text = p.Text,
			Quote = p.Quote,
			Why = p.Why,
			DueAt = p.DueAt,
			Priority = p.Priority ?? 1,
			Done = p.Done ?? false,
			CompletedAt = p.CompletedAt,
			ArchivedAt = p.ArchivedAt,
			SnoozedUntil = p.SnoozedUntil,
			Origin = origin,
			Stage = stage,
			SourceConversationId = p.SourceConversationId,
			SourceAt = p.SourceAt,
			SourceEndAt = p.SourceEndAt,
			SourceApproximate = p.SourceApproximate ?? false,
			CreatedAt = createdAt,
			EditedAt = p.EditedAt,
		});
	}

	// §2.6

	private static Parsed<Note> Note(string id, NotePayload p)
	{
		if (!WireNames.TryParse(p.Origin, out ContentOrigin origin))
		{
			return Unknown<Note>("origin", p.Origin);
		}

		if (p.CreatedAt is not { } createdAt)
		{
			return Missing<Note>("createdAt");
		}

		var citations = new List<NoteCitation>();
		for (var i = 0; i < (p.Citations?.Count ?? 0); i++)
		{
			var citation = p.Citations![i];
			if (citation?.At is not { } at)
			{
				return Missing<Note>($"citations[{i}].at");
			}

			citations.Add(new NoteCitation
			{
				ConversationId = citation.ConversationId ?? p.ConversationId ?? "",
				At = at,
				EndAt = citation.EndAt,
			});
		}

		return Parsed<Note>.Ok(new Note
		{
			Id = id,
			ConversationId = p.ConversationId,
			TemplateId = p.TemplateId,
			Title = p.Title,
			Body = p.Body ?? "",
			Citations = citations,
			Origin = origin,
			Provider = p.Provider,
			Model = p.Model,
			CreatedAt = createdAt,
			EditedAt = p.EditedAt,
		});
	}

	private static Parsed<Person> Person(string id, PersonPayload p) =>
		p.Name is null ? Missing<Person>("name") : Parsed<Person>.Ok(new Person { Id = id, Name = p.Name });

	// §2.7

	private static Parsed<CoverageDay> Coverage(string id, CoveragePayload p)
	{
		if (!SyncJson.TryParseDay(id, out var day))
		{
			return Parsed<CoverageDay>.Fail($"id: '{id}' is not a day");
		}

		if (p.DayKey is { } dayKey && dayKey != id)
		{
			return Parsed<CoverageDay>.Fail("payload: dayKey is not the item's id");
		}

		var spans = new List<CoverageSpan>();
		for (var i = 0; i < (p.Spans?.Count ?? 0); i++)
		{
			var span = p.Spans![i];
			if (span?.StartedAt is not { } start || span.EndedAt is not { } end)
			{
				return Missing<CoverageDay>($"spans[{i}].startedAt or endedAt");
			}

			if (!WireNames.TryParse(span.Kind, out CoverageKind kind))
			{
				return Unknown<CoverageDay>($"spans[{i}].kind", span.Kind);
			}

			spans.Add(new CoverageSpan { StartedAt = start, EndedAt = end, Kind = kind });
		}

		return Parsed<CoverageDay>.Ok(new CoverageDay
		{
			DayKey = day,
			TimeZone = p.TimeZone ?? "",
			Spans = spans,
			RecordedMs = p.RecordedMs ?? 0,
			QuietMs = p.QuietMs ?? 0,
			MissingMs = p.MissingMs ?? 0,
		});
	}

	private static Parsed<T> Missing<T>(string field)
		where T : class => Parsed<T>.Fail($"payload: {field} missing");

	private static Parsed<T> Unknown<T>(string field, string? value)
		where T : class => Parsed<T>.Fail(value is null ? $"payload: {field} missing" : $"payload: {field} '{value}' is not known");

	// The wire shapes. Every field is optional here; the readers above decide what is required.

	private sealed class ConversationPayload
	{
		public DateTimeOffset? StartedAt { get; init; }
		public DateTimeOffset? EndedAt { get; init; }
		public string? TimeZone { get; init; }
		public string? DayKey { get; init; }
		public string? State { get; init; }
		public string? StartReason { get; init; }
		public bool? Provisional { get; init; }
		public string? Title { get; init; }
		public string? Summary { get; init; }
		public List<string?>? Tags { get; init; }
		public bool? TitleEditedByUser { get; init; }
		public bool? IsFinal { get; init; }
		public string? AnnotationProvider { get; init; }
		public string? AnnotationModel { get; init; }
		public string? ContentKind { get; init; }
		public string? ContentDescriptor { get; init; }
		public bool? MostlyQuiet { get; init; }
		public bool? HasMissingAudio { get; init; }
		public long? RecordedMs { get; init; }
		public long? MissingMs { get; init; }
		public List<PiecePayload?>? Pieces { get; init; }
		public List<SpeakerPayload?>? People { get; init; }
		public List<GapPayload?>? Gaps { get; init; }
	}

	private sealed class PiecePayload
	{
		public int? Ordinal { get; init; }
		public string? SegmentId { get; init; }
		public long? StartMediaMs { get; init; }
		public long? EndMediaMs { get; init; }
		public DateTimeOffset? StartedAt { get; init; }
		public DateTimeOffset? EndedAt { get; init; }
	}

	private sealed class SpeakerPayload
	{
		public string? Label { get; init; }
		public string? PersonId { get; init; }
		public string? Name { get; init; }
		public List<VoiceEvidence>? VoiceEvidence { get; init; }
	}

	private sealed class GapPayload
	{
		public DateTimeOffset? StartedAt { get; init; }
		public DateTimeOffset? EndedAt { get; init; }
		public string? Kind { get; init; }
		public string? Origin { get; init; }
		public string? Reason { get; init; }
		public long? MissingMs { get; init; }
		public string? Label { get; init; }
		public string? Cause { get; init; }
		public List<CausePayload?>? Causes { get; init; }
		public bool? Shown { get; init; }
	}

	private sealed class CausePayload
	{
		public string? Code { get; init; }
		public string? Text { get; init; }
		public long? Ms { get; init; }
		public int? Count { get; init; }
	}

	private sealed class TranscriptPayload
	{
		public string? ConversationId { get; init; }
		public string? SourceHash { get; init; }
		public string? Provider { get; init; }
		public string? Model { get; init; }
		public string? Language { get; init; }
		public int? CharCount { get; init; }
		public string? Text { get; init; }
		public List<TranscriptItemPayload?>? Items { get; init; }
		public List<TranscriptSpeakerPatch.Range>? SpeakerRanges { get; init; }
	}

	private sealed class TranscriptItemPayload
	{
		public string? Kind { get; init; }
		public DateTimeOffset? At { get; init; }
		public DateTimeOffset? EndAt { get; init; }
		public string? Speaker { get; init; }
		public string? Name { get; init; }
		public string? Text { get; init; }
		public double? Confidence { get; init; }
		public string? Origin { get; init; }
		public string? Descriptor { get; init; }
		public string? Label { get; init; }
		public string? Cause { get; init; }
		public long? MissingMs { get; init; }
		public string? Reason { get; init; }
	}

	private sealed class RecapPayload
	{
		public string? DayKey { get; init; }
		public string? TimeZone { get; init; }
		public string? Headline { get; init; }
		public string? LineSummary { get; init; }
		public string? ShortText { get; init; }
		public string? Text { get; init; }
		public List<string?>? ConversationIds { get; init; }
		public string? Provider { get; init; }
		public string? Model { get; init; }
	}

	private sealed class BriefPayload
	{
		public string? Kind { get; init; }
		public string? PeriodKey { get; init; }
		public string? StartDay { get; init; }
		public string? EndDay { get; init; }
		public string? Headline { get; init; }
		public string? LineSummary { get; init; }
		public string? Text { get; init; }
		public string? Provider { get; init; }
		public string? Model { get; init; }
	}

	private sealed class FollowUpPayload
	{
		public string? Text { get; init; }
		public string? Quote { get; init; }
		public string? Why { get; init; }
		public DateTimeOffset? DueAt { get; init; }
		public int? Priority { get; init; }
		public bool? Done { get; init; }
		public DateTimeOffset? CompletedAt { get; init; }
		public DateTimeOffset? ArchivedAt { get; init; }
		public DateTimeOffset? SnoozedUntil { get; init; }
		public string? Origin { get; init; }
		public string? Stage { get; init; }
		public string? SourceConversationId { get; init; }
		public DateTimeOffset? SourceAt { get; init; }
		public DateTimeOffset? SourceEndAt { get; init; }
		public bool? SourceApproximate { get; init; }
		public DateTimeOffset? CreatedAt { get; init; }
		public DateTimeOffset? EditedAt { get; init; }
	}

	private sealed class NotePayload
	{
		public string? ConversationId { get; init; }
		public string? TemplateId { get; init; }
		public string? Title { get; init; }
		public string? Body { get; init; }
		public List<CitationPayload?>? Citations { get; init; }
		public string? Origin { get; init; }
		public string? Provider { get; init; }
		public string? Model { get; init; }
		public DateTimeOffset? CreatedAt { get; init; }
		public DateTimeOffset? EditedAt { get; init; }
	}

	private sealed class CitationPayload
	{
		public string? ConversationId { get; init; }
		public DateTimeOffset? At { get; init; }
		public DateTimeOffset? EndAt { get; init; }
	}

	private sealed class PersonPayload
	{
		public string? Name { get; init; }
	}

	private sealed class CoveragePayload
	{
		public string? DayKey { get; init; }
		public string? TimeZone { get; init; }
		public List<SpanPayload?>? Spans { get; init; }
		public long? RecordedMs { get; init; }
		public long? QuietMs { get; init; }
		public long? MissingMs { get; init; }
	}

	private sealed class SpanPayload
	{
		public DateTimeOffset? StartedAt { get; init; }
		public DateTimeOffset? EndedAt { get; init; }
		public string? Kind { get; init; }
	}
}

/// <summary>A value read from the wire, or why it could not be.</summary>
internal readonly record struct Parsed<T>(T? Value, string? Error)
	where T : class
{
	public static Parsed<T> Ok(T value) => new(value, null);

	public static Parsed<T> Fail(string error) => new(null, error);
}
