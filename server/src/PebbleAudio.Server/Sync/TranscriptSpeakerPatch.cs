using System.Text.Json;
using PebbleAudio.Server.Data;

namespace PebbleAudio.Server.Sync;

/// <summary>Names-only overlays. The source transcript's words and markers are never replaced.</summary>
public static class TranscriptSpeakerPatch
{
	public sealed class Range
	{
		public int? ItemIndex { get; init; }
		public string? SegmentId { get; init; }
		public long? StartMediaMs { get; init; }
		public long? EndMediaMs { get; init; }
		public DateTimeOffset? At { get; init; }
		public DateTimeOffset? EndAt { get; init; }
		public string? PersonId { get; init; }
		public string? Name { get; init; }
		public List<VoiceEvidence>? VoiceEvidence { get; init; }
	}

	public sealed class Payload
	{
		public string? ConversationId { get; init; }
		public string? SourceHash { get; init; }
		public List<Range>? Ranges { get; init; }
	}

	public static bool TryRead(JsonElement json, string id, out Payload? payload, out string error)
	{
		payload = null;
		error = "payload: invalid speaker patch";
		try { payload = json.Deserialize<Payload>(SyncJson.Options); }
		catch (JsonException) { return false; }
		if (payload?.ConversationId != id || string.IsNullOrEmpty(payload.SourceHash) || payload.Ranges is not { Count: > 0 and <= 5000 })
		{
			return false;
		}

		return payload.Ranges.All(Valid);
	}

	public static bool Valid(Range? range) => range is not null
		&& !string.IsNullOrWhiteSpace(range.SegmentId)
		&& range.StartMediaMs is >= 0 && range.EndMediaMs > range.StartMediaMs
		&& range.At is not null && range.EndAt > range.At
		&& (range.Name is null || !string.IsNullOrWhiteSpace(range.Name) && range.Name.Length <= 512)
		&& (range.PersonId is null || !string.IsNullOrWhiteSpace(range.PersonId) && range.PersonId.Length <= 512)
		&& (range.Name is not null || range.PersonId is null)
		&& (range.VoiceEvidence is null || range.VoiceEvidence.Count <= 256
			&& range.VoiceEvidence.All(ArchiveVoiceRevocations.Valid)
			&& (range.VoiceEvidence.Count == 0 || range.Name is not null && range.PersonId is not null));

	public static bool Apply(Transcript transcript, Conversation? conversation, Payload patch)
	{
		var changed = false;
		var originalTurnNames = transcript.Items.Select(i => i.Name).OfType<string>().ToHashSet();
		foreach (var item in transcript.Items.Where(i => i.Kind == TranscriptItemKind.Turn))
		{
			List<Range> intersecting;
			long start, end;
			var anchored = item.SegmentId is not null && item.StartMediaMs is >= 0 && item.EndMediaMs > item.StartMediaMs;
			if (anchored)
			{
				start = item.StartMediaMs!.Value;
				end = item.EndMediaMs!.Value;
				intersecting = patch.Ranges!.Where(r => r.SegmentId == item.SegmentId && r.StartMediaMs < end && r.EndMediaMs > start)
					.OrderBy(r => r.StartMediaMs).ToList();
			}
			else
			{
				if (conversation is null || item.EndAt is not { } itemEnd || itemEnd <= item.At) { continue; }
				// Legacy exports have only wall time. Resolve a source only when exactly one stored
				// piece encloses this whole turn; repeated/uncertain wall clocks must never guess.
				var pieces = conversation.Pieces.Where(p => p.StartedAt <= item.At && p.EndedAt >= itemEnd).ToList();
				if (pieces.Count != 1) { continue; }
				var piece = pieces[0];
				start = item.At.ToUnixTimeMilliseconds();
				end = itemEnd.ToUnixTimeMilliseconds();
				intersecting = patch.Ranges!.Where(r => r.SegmentId == piece.SegmentId
					&& r.StartMediaMs >= piece.StartMediaMs && (piece.EndMediaMs is null || r.EndMediaMs <= piece.EndMediaMs)
					&& r.At >= piece.StartedAt && (piece.EndedAt is null || r.EndAt <= piece.EndedAt)
					&& r.At < itemEnd && r.EndAt > item.At).OrderBy(r => r.At).ToList();
			}

			if (intersecting.Count == 0) { continue; }
			var first = intersecting[0];
			var through = start;
			var consistent = true;
			foreach (var range in intersecting)
			{
				var lower = anchored ? range.StartMediaMs!.Value : range.At!.Value.ToUnixTimeMilliseconds();
				var upper = anchored ? range.EndMediaMs!.Value : range.EndAt!.Value.ToUnixTimeMilliseconds();
				if (lower > through || range.PersonId != first.PersonId || range.Name != first.Name) { consistent = false; }
				through = Math.Max(through, upper);
			}

			var name = consistent && through >= end ? first.Name : null;
			var personId = name is null ? null : first.PersonId;
			changed |= item.Name != name || item.PersonId != personId || item.IdentityResolved != true;
			item.Name = name;
			item.PersonId = personId;
			item.IdentityResolved = true;
			item.VoiceEvidence = name is null ? [] : intersecting.SelectMany(r => r.VoiceEvidence ?? [])
				.DistinctBy(e => (e.OriginID, e.Generation, e.RunID)).ToList();
		}

		if (changed)
		{
			Rebuild(transcript, conversation, originalTurnNames);
		}
		transcript.SourceHash = patch.SourceHash;
		return changed;
	}

	public static void Rebuild(Transcript transcript, Conversation? conversation, IReadOnlySet<string> originalTurnNames)
	{
		transcript.Text = string.Join("\n", transcript.Items.Where(i => i.Kind == TranscriptItemKind.Turn)
			.Select(i => string.IsNullOrEmpty(i.Name)
				? string.IsNullOrEmpty(i.Speaker) ? i.Text : $"{SpeakerLabel(i.Speaker)}: {i.Text}"
				: $"{i.Name}: {i.Text}"));
		transcript.CharCount = transcript.Text.Length;
		if (conversation is null) { return; }
		var old = conversation.People;
		// Preserve audio-only participant metadata that was never represented by a text turn.
		var audioOnly = old.Where(p => p.Name is { } name && !originalTurnNames.Contains(name));
		conversation.People = transcript.Items.Where(i => i.Kind == TranscriptItemKind.Turn && i.Name is not null)
			.Select(i => new ConversationSpeaker
			{
				Label = i.Speaker ?? i.PersonId ?? "?", Name = i.Name,
				PersonId = i.PersonId ?? UniqueLegacyPerson(old, i.Name!),
				VoiceEvidence = i.VoiceEvidence,
			})
			.Concat(audioOnly).GroupBy(p => p.PersonId is { } person ? $"id:{person}" : $"name:{p.Name}")
			.Select(group =>
			{
				var person = group.First();
				person.VoiceEvidence = group.Any(p => p.VoiceEvidence.Count == 0) ? []
					: group.SelectMany(p => p.VoiceEvidence).DistinctBy(e => (e.OriginID, e.Generation, e.RunID)).ToList();
				return person;
			}).ToList();
	}

	private static string? UniqueLegacyPerson(List<ConversationSpeaker> old, string name)
	{
		var ids = old.Where(p => p.Name == name).Select(p => p.PersonId).Distinct().ToList();
		return ids.Count == 1 ? ids[0] : null;
	}

	private static string SpeakerLabel(string speaker) => speaker.StartsWith("Speaker ", StringComparison.OrdinalIgnoreCase)
		? speaker : $"Speaker {speaker}";
}
