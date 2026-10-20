using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.EntityFrameworkCore;
using PebbleAudio.Server.Data;
using PebbleAudio.Server.Jobs;
using PebbleAudio.Server.Settings;

namespace PebbleAudio.Server.Sync;

/// <summary>
/// The server's half of the request channel (sync-protocol.md §4), and the service the assistant tools call to
/// reach the phone: <see cref="RequestClipAsync"/> for audio, and <see cref="CreateFollowUpAsync"/>,
/// <see cref="UpdateFollowUpAsync"/>, and <see cref="CreateNoteAsync"/> for writes. Each honours what the person
/// allowed on the phone (<c>PUT /sync/preferences</c>) and answers with a typed outcome a tool can put in words.
/// </summary>
/// <remarks>
/// A write is stored here at once with origin <c>assistant</c> and version 0, so tools can read it back, and the
/// matching request goes to the phone. The phone's own upsert of it (any real version) replaces the row. If the
/// phone refuses a create, or never answers within the request time to live, the unconfirmed row is removed again:
/// the phone is the system of record.
/// </remarks>
public sealed class PhoneRequestService(
	ArchiveDbContext db,
	SettingsService settingsService,
	ClipLinks links,
	ClipStorage storage,
	IJobQueue queue,
	TimeProvider time)
{
	/// <summary>Requests handed to the phone per pull.</summary>
	public const int PullLimit = 100;

	private const int DetailLength = 2000;

	// Preferences (§5)

	/// <summary>What the person allowed on the phone; both off until the phone says otherwise.</summary>
	public async Task<SyncPreferences> GetPreferencesAsync(Guid userId, CancellationToken cancellationToken) =>
		await db.SyncPreferences.AsNoTracking().SingleOrDefaultAsync(p => p.UserId == userId, cancellationToken)
		?? new SyncPreferences { UserId = userId };

	/// <summary>Stores the phone's choices. A choice left out keeps its stored value.</summary>
	public async Task<SyncPreferences> SetPreferencesAsync(
		Guid userId,
		Guid deviceId,
		bool? clips,
		bool? edits,
		CancellationToken cancellationToken)
	{
		var row = await db.SyncPreferences.SingleOrDefaultAsync(p => p.UserId == userId, cancellationToken);
		if (row is null)
		{
			row = new SyncPreferences { UserId = userId };
			db.SyncPreferences.Add(row);
		}

		row.Clips = clips ?? row.Clips;
		row.Edits = edits ?? row.Edits;
		row.UpdatedAt = time.GetUtcNow();
		row.DeviceId = deviceId;
		await db.SaveChangesAsync(cancellationToken);
		return row;
	}

	// Clips

	/// <summary>
	/// A clip of one conversation from <paramref name="startAt"/> to <paramref name="endAt"/>: the ready one if the
	/// server has it, the pending request if one is on its way, or a new request to the phone. The span is kept
	/// inside the conversation and to the <c>ClipMaxMinutes</c> setting.
	/// </summary>
	/// <exception cref="ArgumentOutOfRangeException">The span holds none of the conversation.</exception>
	public async Task<ClipRequestResult> RequestClipAsync(
		Guid userId,
		string conversationId,
		DateTimeOffset startAt,
		DateTimeOffset endAt,
		CancellationToken cancellationToken)
	{
		if (!(await GetPreferencesAsync(userId, cancellationToken)).Clips)
		{
			return ClipRequestResult.Without(ClipOutcome.NotAllowed, conversationId, "Clips are turned off on the phone.");
		}

		var conversation = await db.Conversations
			.AsNoTracking()
			.Where(c => c.UserId == userId && c.Id == conversationId)
			.Select(c => new { c.StartedAt, c.EndedAt, c.ExpiredOnPhoneAt })
			.SingleOrDefaultAsync(cancellationToken);
		if (conversation is null)
		{
			return ClipRequestResult.Without(ClipOutcome.NotFound, conversationId, null);
		}

		var settings = await settingsService.GetAsync(cancellationToken);
		var start = Milliseconds(Later(startAt.ToUniversalTime(), conversation.StartedAt));
		var end = Milliseconds(conversation.EndedAt is { } ended ? Earlier(endAt.ToUniversalTime(), ended) : endAt.ToUniversalTime());
		if (end - start > settings.ClipMaxDuration)
		{
			end = start + settings.ClipMaxDuration;
		}

		if (end <= start)
		{
			throw new ArgumentOutOfRangeException(nameof(endAt), "The span holds none of the conversation.");
		}

		await ExpireDueAsync(userId, cancellationToken);
		var now = time.GetUtcNow();
		var latest = await db.Clips
			.AsNoTracking()
			.Where(c => c.UserId == userId && c.ConversationId == conversationId && c.StartAt == start && c.EndAt == end)
			.OrderByDescending(c => c.CreatedAt)
			.FirstOrDefaultAsync(cancellationToken);
		if (latest is not null)
		{
			var request = await db.Requests.AsNoTracking().SingleAsync(r => r.Id == latest.RequestId, cancellationToken);
			var described = await DescribeAsync(latest, request, cancellationToken);
			switch (described.Outcome)
			{
				case ClipOutcome.Ready when latest.Path is not null && File.Exists(storage.Resolve(latest.Path)):
				case ClipOutcome.Waiting:
					return described;
				case ClipOutcome.Unavailable or ClipOutcome.Failed
					when (request.CompletedAt ?? latest.CreatedAt) + settings.RequestTtl > now:
					// The phone's answer stands for a while; asking again at once would get the same one.
					return described;
			}
		}

		if (conversation.ExpiredOnPhoneAt is not null)
		{
			return ClipRequestResult.Without(ClipOutcome.Unavailable, conversationId, "The phone no longer keeps this conversation's audio.");
		}

		var phoneRequest = NewRequest(
			userId,
			PhoneRequestKind.Clip,
			JsonSerializer.SerializeToDocument(
				new ClipRequestPayload(conversationId, start, end, (long)settings.ClipMaxDuration.TotalMilliseconds),
				SyncJson.Options),
			settings);
		var clip = new Clip
		{
			Id = Guid.CreateVersion7(),
			UserId = userId,
			RequestId = phoneRequest.Id,
			ConversationId = conversationId,
			StartAt = start,
			EndAt = end,
			Status = ClipStatus.Waiting,
			CreatedAt = now,
		};
		db.Requests.Add(phoneRequest);
		db.Clips.Add(clip);
		await db.SaveChangesAsync(cancellationToken);
		return await DescribeAsync(clip, phoneRequest, cancellationToken);
	}

	/// <summary>Where a clip request stands now, by the request id a earlier result gave.</summary>
	public async Task<ClipRequestResult?> GetClipRequestAsync(Guid userId, Guid requestId, CancellationToken cancellationToken)
	{
		await ExpireDueAsync(userId, cancellationToken);
		var request = await db.Requests.AsNoTracking().SingleOrDefaultAsync(r => r.Id == requestId && r.UserId == userId, cancellationToken);
		var clip = await db.Clips.AsNoTracking().SingleOrDefaultAsync(c => c.RequestId == requestId, cancellationToken);
		return request is null || clip is null ? null : await DescribeAsync(clip, request, cancellationToken);
	}

	private async Task<ClipRequestResult> DescribeAsync(Clip clip, PhoneRequest request, CancellationToken cancellationToken)
	{
		var outcome = clip.Status switch
		{
			ClipStatus.Ready => ClipOutcome.Ready,
			ClipStatus.Received => ClipOutcome.Waiting,
			ClipStatus.Failed => ClipOutcome.Failed,
			ClipStatus.Unavailable => ClipOutcome.Unavailable,
			ClipStatus.Waiting => request.State switch
			{
				PhoneRequestState.Pending or PhoneRequestState.Done => ClipOutcome.Waiting,
				PhoneRequestState.Failed => ClipOutcome.Failed,
				PhoneRequestState.Unavailable => ClipOutcome.Unavailable,
				PhoneRequestState.Expired => ClipOutcome.NotDelivered,
			},
		};

		return new ClipRequestResult(
			outcome,
			clip.ConversationId,
			clip.StartAt,
			clip.EndAt,
			request.Id,
			clip.Id,
			outcome == ClipOutcome.Waiting ? request.ExpiresAt : null,
			clip.CoveredStartAt,
			clip.CoveredEndAt,
			clip.Gaps,
			clip.DurationMs,
			outcome == ClipOutcome.Ready ? await links.CreateAsync(clip.Id, cancellationToken) : null,
			outcome == ClipOutcome.NotDelivered ? "The phone did not deliver it in time." : clip.Error ?? request.Detail);
	}

	// Writes

	/// <summary>Adds a follow-up on the person's behalf and asks the phone to add it too.</summary>
	/// <exception cref="ArgumentException">The follow-up has no text.</exception>
	public async Task<PhoneWriteResult<FollowUp>> CreateFollowUpAsync(Guid userId, FollowUpDraft draft, CancellationToken cancellationToken)
	{
		var text = draft.Text?.Trim();
		if (string.IsNullOrEmpty(text))
		{
			throw new ArgumentException("A follow-up needs text.", nameof(draft));
		}

		if (!(await GetPreferencesAsync(userId, cancellationToken)).Edits)
		{
			return new(PhoneWriteOutcome.NotAllowed, null, null);
		}

		var settings = await settingsService.GetAsync(cancellationToken);
		var now = time.GetUtcNow();
		var followUp = new FollowUp
		{
			UserId = userId,
			Id = $"fu-assistant-{Guid.CreateVersion7():N}",
			Version = 0,
			ChangedAt = now,
			ReceivedAt = now,
			Text = text,
			Quote = draft.Quote,
			Why = draft.Why,
			DueAt = draft.DueAt?.ToUniversalTime(),
			Priority = Math.Clamp(draft.Priority, 0, 2),
			Origin = ContentOrigin.Assistant,
			SourceConversationId = draft.SourceConversationId,
			SourceAt = draft.SourceAt?.ToUniversalTime(),
			SourceEndAt = draft.SourceEndAt?.ToUniversalTime(),
			SourceApproximate = draft.SourceApproximate,
			CreatedAt = now,
		};

		var payload = new FollowUpCreatePayload(
			followUp.Id,
			followUp.Text,
			followUp.Quote,
			followUp.Why,
			followUp.DueAt,
			followUp.Priority,
			followUp.Done,
			followUp.CompletedAt,
			followUp.ArchivedAt,
			followUp.SnoozedUntil,
			ContentOrigin.Assistant.ToWire(),
			followUp.SourceConversationId,
			followUp.SourceAt,
			followUp.SourceEndAt,
			followUp.SourceApproximate,
			followUp.CreatedAt,
			followUp.EditedAt);
		var request = NewRequest(userId, PhoneRequestKind.FollowUpCreate, JsonSerializer.SerializeToDocument(payload, SyncJson.Options), settings);
		db.FollowUps.Add(followUp);
		db.Requests.Add(request);
		await db.SaveChangesAsync(cancellationToken);
		return new(PhoneWriteOutcome.Queued, followUp, request.Id);
	}

	/// <summary>Changes a follow-up (mark done, edit, snooze, archive) and asks the phone to make the same change.</summary>
	public async Task<PhoneWriteResult<FollowUp>> UpdateFollowUpAsync(
		Guid userId,
		string followUpId,
		FollowUpChange change,
		CancellationToken cancellationToken)
	{
		if (!(await GetPreferencesAsync(userId, cancellationToken)).Edits)
		{
			return new(PhoneWriteOutcome.NotAllowed, null, null);
		}

		var followUp = await db.FollowUps.SingleOrDefaultAsync(f => f.UserId == userId && f.Id == followUpId, cancellationToken);
		if (followUp is null)
		{
			return new(PhoneWriteOutcome.NotFound, null, null);
		}

		var now = time.GetUtcNow();
		var payload = new JsonObject { ["id"] = followUpId };
		if (change.Done is { } done)
		{
			followUp.Done = done;
			followUp.CompletedAt = done ? (change.CompletedAt ?? now).ToUniversalTime() : null;
			payload["done"] = done;
			payload["completedAt"] = Instant(followUp.CompletedAt);
		}

		if (change.Text?.Trim() is { Length: > 0 } text && text != followUp.Text)
		{
			followUp.Text = text;
			followUp.EditedAt = now;
			payload["text"] = text;
		}

		if (change.DueAt is { } dueAt)
		{
			followUp.DueAt = dueAt.Value?.ToUniversalTime();
			payload["dueAt"] = Instant(followUp.DueAt);
		}

		if (change.SnoozedUntil is { } snoozedUntil)
		{
			followUp.SnoozedUntil = snoozedUntil.Value?.ToUniversalTime();
			payload["snoozedUntil"] = Instant(followUp.SnoozedUntil);
		}

		if (change.ArchivedAt is { } archivedAt)
		{
			followUp.ArchivedAt = archivedAt.Value?.ToUniversalTime();
			payload["archivedAt"] = Instant(followUp.ArchivedAt);
		}

		if (payload.Count == 1)
		{
			return new(PhoneWriteOutcome.Unchanged, followUp, null);
		}

		var settings = await settingsService.GetAsync(cancellationToken);
		var request = NewRequest(userId, PhoneRequestKind.FollowUpUpdate, JsonDocument.Parse(payload.ToJsonString()), settings);
		db.Requests.Add(request);
		await db.SaveChangesAsync(cancellationToken);
		return new(PhoneWriteOutcome.Queued, followUp, request.Id);
	}

	/// <summary>Adds a note to a conversation on the person's behalf and asks the phone to add it too.</summary>
	/// <exception cref="ArgumentException">The note has neither a title nor a body.</exception>
	public async Task<PhoneWriteResult<Note>> CreateNoteAsync(Guid userId, NoteDraft draft, CancellationToken cancellationToken)
	{
		if (string.IsNullOrWhiteSpace(draft.Title) && string.IsNullOrWhiteSpace(draft.Body))
		{
			throw new ArgumentException("A note needs a title or a body.", nameof(draft));
		}

		if (!(await GetPreferencesAsync(userId, cancellationToken)).Edits)
		{
			return new(PhoneWriteOutcome.NotAllowed, null, null);
		}

		if (!await db.Conversations.AnyAsync(c => c.UserId == userId && c.Id == draft.ConversationId, cancellationToken))
		{
			return new(PhoneWriteOutcome.NotFound, null, null);
		}

		var settings = await settingsService.GetAsync(cancellationToken);
		var now = time.GetUtcNow();
		var note = new Note
		{
			UserId = userId,
			Id = $"note-assistant-{Guid.CreateVersion7():N}",
			Version = 0,
			ChangedAt = now,
			ReceivedAt = now,
			ConversationId = draft.ConversationId,
			TemplateId = draft.TemplateId ?? "assistant",
			Title = draft.Title?.Trim() ?? "",
			Body = draft.Body?.Trim() ?? "",
			Citations =
			[
				.. (draft.Citations ?? []).Select(c => new NoteCitation
				{
					ConversationId = c.ConversationId is { Length: > 0 } id ? id : draft.ConversationId,
					At = c.At.ToUniversalTime(),
					EndAt = c.EndAt?.ToUniversalTime(),
				}),
			],
			Origin = ContentOrigin.Assistant,
			Provider = draft.Provider,
			Model = draft.Model,
			CreatedAt = now,
		};

		var payload = new NoteCreatePayload(
			note.Id,
			draft.ConversationId,
			note.TemplateId,
			note.Title,
			note.Body,
			[.. note.Citations.Select(c => new NoteCitationPayload(c.ConversationId, c.At, c.EndAt))],
			ContentOrigin.Assistant.ToWire(),
			note.Provider,
			note.Model,
			note.CreatedAt,
			note.EditedAt);
		var request = NewRequest(userId, PhoneRequestKind.NoteCreate, JsonSerializer.SerializeToDocument(payload, SyncJson.Options), settings);
		db.Notes.Add(note);
		db.Requests.Add(request);
		await db.SaveChangesAsync(cancellationToken);
		return new(PhoneWriteOutcome.Queued, note, request.Id);
	}

	// The phone's side of the channel

	/// <summary>
	/// The requests waiting for the phone, oldest first, each marked delivered the first time it is handed over.
	/// A request is offered on every pull until the phone answers it or it expires.
	/// </summary>
	internal async Task<List<PhoneRequest>> PullAsync(Guid userId, CancellationToken cancellationToken)
	{
		await ExpireDueAsync(userId, cancellationToken);
		var now = time.GetUtcNow();
		var pending = await db.Requests
			.Where(r => r.UserId == userId && r.State == PhoneRequestState.Pending)
			.OrderBy(r => r.CreatedAt)
			.Take(PullLimit)
			.ToListAsync(cancellationToken);
		foreach (var request in pending.Where(r => r.DeliveredAt is null))
		{
			request.DeliveredAt = now;
		}

		await db.SaveChangesAsync(cancellationToken);
		return pending;
	}

	internal async Task<int> CountPendingAsync(Guid userId, CancellationToken cancellationToken)
	{
		await ExpireDueAsync(userId, cancellationToken);
		return await db.Requests.CountAsync(r => r.UserId == userId && r.State == PhoneRequestState.Pending, cancellationToken);
	}

	/// <summary>
	/// The phone's answer to a request. The first answer stands; a late one still replaces "expired", because the
	/// truth is better than a timeout.
	/// </summary>
	/// <returns>False when the user has no such request.</returns>
	internal async Task<bool> RecordResultAsync(
		Guid userId,
		Guid requestId,
		PhoneRequestState state,
		string? detail,
		CancellationToken cancellationToken)
	{
		var request = await db.Requests.SingleOrDefaultAsync(r => r.Id == requestId && r.UserId == userId, cancellationToken);
		if (request is null)
		{
			return false;
		}

		if (request.State is not (PhoneRequestState.Pending or PhoneRequestState.Expired))
		{
			return true;
		}

		request.State = state;
		request.CompletedAt = time.GetUtcNow();
		request.Detail = detail is { Length: > DetailLength } ? detail[..DetailLength] : detail;
		if (request.Kind == PhoneRequestKind.Clip &&
			await db.Clips.SingleOrDefaultAsync(c => c.RequestId == requestId, cancellationToken) is { Status: ClipStatus.Waiting } clip)
		{
			clip.Status = state switch
			{
				PhoneRequestState.Unavailable => ClipStatus.Unavailable,
				PhoneRequestState.Failed => ClipStatus.Failed,
				PhoneRequestState.Pending or PhoneRequestState.Done or PhoneRequestState.Expired => clip.Status,
			};
			clip.Error = clip.Status == ClipStatus.Waiting ? clip.Error : request.Detail;
		}

		if (state != PhoneRequestState.Done)
		{
			await RemoveUnconfirmedAsync(request, cancellationToken);
		}

		await db.SaveChangesAsync(cancellationToken);
		return true;
	}

	/// <summary>
	/// Stores an uploaded clip and queues its transcode. The audio is written beside its final name and moved
	/// into place, so a half-written upload is never served.
	/// </summary>
	internal async Task<ClipUpload> ReceiveClipAsync(
		Guid userId,
		Guid requestId,
		DateTimeOffset? coveredStartAt,
		DateTimeOffset? coveredEndAt,
		List<ClipGap> gaps,
		Stream body,
		CancellationToken cancellationToken)
	{
		var request = await db.Requests.SingleOrDefaultAsync(
			r => r.Id == requestId && r.UserId == userId && r.Kind == PhoneRequestKind.Clip,
			cancellationToken);
		var clip = request is null ? null : await db.Clips.SingleOrDefaultAsync(c => c.RequestId == requestId, cancellationToken);
		if (request is null || clip is null)
		{
			return new ClipUpload(ClipUploadOutcome.NotFound, null);
		}

		if (clip.Status is ClipStatus.Received or ClipStatus.Ready)
		{
			// A retried upload of audio the server already has.
			return new ClipUpload(ClipUploadOutcome.Stored, clip.Id);
		}

		var relative = ClipStorage.RelativePath(userId, clip.Id, ".ogg");
		var path = storage.Resolve(relative);
		Directory.CreateDirectory(Path.GetDirectoryName(path)!);
		var partial = path + ".upload";
		long size;
		var header = new byte[4];
		await using (var file = new FileStream(partial, FileMode.Create, FileAccess.ReadWrite, FileShare.None, 81920, useAsync: true))
		{
			await body.CopyToAsync(file, cancellationToken);
			size = file.Length;
			file.Position = 0;
			_ = await file.ReadAtLeastAsync(header, header.Length, throwOnEndOfStream: false, cancellationToken);
		}

		if (size == 0 || !OggSpeexInfo.LooksLikeOgg(header))
		{
			File.Delete(partial);
			return new ClipUpload(ClipUploadOutcome.NotOgg, clip.Id);
		}

		File.Move(partial, path, overwrite: true);
		var now = time.GetUtcNow();
		clip.CoveredStartAt = coveredStartAt ?? clip.StartAt;
		clip.CoveredEndAt = coveredEndAt ?? clip.EndAt;
		clip.Gaps = gaps;
		clip.Path = relative;
		clip.ByteCount = size;
		clip.Status = ClipStatus.Received;
		clip.UploadedAt = now;
		clip.Error = null;
		request.State = PhoneRequestState.Done;
		request.CompletedAt = now;
		request.Detail = null;
		// Saves the clip, the request, and the job together.
		await queue.EnqueueAsync(ClipTranscodeJob.Type, new ClipTranscodeJob.Payload(clip.Id), userId: userId, cancellationToken: cancellationToken);
		return new ClipUpload(ClipUploadOutcome.Stored, clip.Id);
	}

	/// <summary>
	/// Marks the requests whose time to live has passed as expired. Run before anything reads the channel, so no
	/// reader ever sees a request that is still "waiting" after it should have stopped.
	/// </summary>
	internal async Task ExpireDueAsync(Guid userId, CancellationToken cancellationToken)
	{
		var now = time.GetUtcNow();
		var due = await db.Requests
			.Where(r => r.UserId == userId && r.State == PhoneRequestState.Pending && r.ExpiresAt <= now)
			.ToListAsync(cancellationToken);
		if (due.Count == 0)
		{
			return;
		}

		foreach (var request in due)
		{
			request.State = PhoneRequestState.Expired;
			request.CompletedAt = now;
			await RemoveUnconfirmedAsync(request, cancellationToken);
		}

		await db.SaveChangesAsync(cancellationToken);
	}

	/// <summary>
	/// A create the phone refused or never took: the row stored for it goes, unless the phone has since synced
	/// its own copy (any version above 0).
	/// </summary>
	private async Task RemoveUnconfirmedAsync(PhoneRequest request, CancellationToken cancellationToken)
	{
		var id = request.Payload.RootElement.TryGetProperty("id", out var value) && value.ValueKind == JsonValueKind.String
			? value.GetString()
			: null;
		switch (request.Kind)
		{
			case PhoneRequestKind.FollowUpCreate when id is not null:
				await db.FollowUps.Where(f => f.UserId == request.UserId && f.Id == id && f.Version == 0).ExecuteDeleteAsync(cancellationToken);
				break;
			case PhoneRequestKind.NoteCreate when id is not null:
				await db.Notes.Where(n => n.UserId == request.UserId && n.Id == id && n.Version == 0).ExecuteDeleteAsync(cancellationToken);
				break;
			case PhoneRequestKind.FollowUpCreate:
			case PhoneRequestKind.NoteCreate:
			case PhoneRequestKind.Clip:
			case PhoneRequestKind.FollowUpUpdate:
				break;
		}
	}

	private PhoneRequest NewRequest(Guid userId, PhoneRequestKind kind, JsonDocument payload, ArchiveSettings settings)
	{
		var now = time.GetUtcNow();
		return new PhoneRequest
		{
			Id = Guid.CreateVersion7(),
			UserId = userId,
			Kind = kind,
			Payload = payload,
			State = PhoneRequestState.Pending,
			CreatedAt = now,
			ExpiresAt = now + settings.RequestTtl,
		};
	}

	private static JsonNode? Instant(DateTimeOffset? value) => value is { } instant ? JsonValue.Create(SyncJson.Format(instant)) : null;

	/// <summary>Postgres keeps microseconds and the wire milliseconds; a span is matched on what both keep.</summary>
	private static DateTimeOffset Milliseconds(DateTimeOffset value) =>
		DateTimeOffset.FromUnixTimeMilliseconds(value.ToUnixTimeMilliseconds());

	private static DateTimeOffset Later(DateTimeOffset a, DateTimeOffset b) => a > b ? a : b;

	private static DateTimeOffset Earlier(DateTimeOffset a, DateTimeOffset b) => a < b ? a : b;

	private sealed record ClipRequestPayload(string ConversationId, DateTimeOffset StartAt, DateTimeOffset EndAt, long MaxMs);

	private sealed record FollowUpCreatePayload(
		string Id,
		string Text,
		string? Quote,
		string? Why,
		DateTimeOffset? DueAt,
		int Priority,
		bool Done,
		DateTimeOffset? CompletedAt,
		DateTimeOffset? ArchivedAt,
		DateTimeOffset? SnoozedUntil,
		string Origin,
		string? SourceConversationId,
		DateTimeOffset? SourceAt,
		DateTimeOffset? SourceEndAt,
		bool SourceApproximate,
		DateTimeOffset CreatedAt,
		DateTimeOffset? EditedAt);

	private sealed record NoteCreatePayload(
		string Id,
		string ConversationId,
		string? TemplateId,
		string? Title,
		string Body,
		IReadOnlyList<NoteCitationPayload> Citations,
		string Origin,
		string? Provider,
		string? Model,
		DateTimeOffset CreatedAt,
		DateTimeOffset? EditedAt);

	private sealed record NoteCitationPayload(string ConversationId, DateTimeOffset At, DateTimeOffset? EndAt);
}

/// <summary>Where a clip stands, as a tool would tell it.</summary>
public enum ClipOutcome
{
	/// <summary>The clip is on the server; <see cref="ClipRequestResult.Link"/> plays it.</summary>
	Ready,

	/// <summary>Asked of the phone, or uploaded and being converted. Ask again later.</summary>
	Waiting,

	/// <summary>The phone no longer has that audio (aged out or deleted).</summary>
	Unavailable,

	/// <summary>The phone or the server could not make the clip.</summary>
	Failed,

	/// <summary>The phone did not answer within the request time to live.</summary>
	NotDelivered,

	/// <summary>The person has turned clips off on the phone; nothing was asked.</summary>
	NotAllowed,

	/// <summary>The archive has no such conversation.</summary>
	NotFound,
}

/// <param name="Outcome">Where it stands.</param>
/// <param name="ConversationId">The conversation it is from.</param>
/// <param name="StartAt">The span asked for, after it was kept inside the conversation and the longest-clip setting.</param>
/// <param name="EndAt">The end of that span.</param>
/// <param name="RequestId">The phone request, to ask about it later with <see cref="PhoneRequestService.GetClipRequestAsync"/>.</param>
/// <param name="ClipId">The clip's id.</param>
/// <param name="WaitingUntil">While waiting: when the request stops waiting for the phone.</param>
/// <param name="CoveredStartAt">The span the audio actually covers, which can be shorter when some was lost.</param>
/// <param name="CoveredEndAt">The end of that span.</param>
/// <param name="Gaps">Lost stretches inside the audio.</param>
/// <param name="DurationMs">How long the audio is.</param>
/// <param name="Link">When ready: a signed link that plays it.</param>
/// <param name="Detail">What the phone or the server said, when there is something to say.</param>
public sealed record ClipRequestResult(
	ClipOutcome Outcome,
	string ConversationId,
	DateTimeOffset? StartAt,
	DateTimeOffset? EndAt,
	Guid? RequestId,
	Guid? ClipId,
	DateTimeOffset? WaitingUntil,
	DateTimeOffset? CoveredStartAt,
	DateTimeOffset? CoveredEndAt,
	IReadOnlyList<ClipGap> Gaps,
	long? DurationMs,
	ClipLink? Link,
	string? Detail)
{
	internal static ClipRequestResult Without(ClipOutcome outcome, string conversationId, string? detail) =>
		new(outcome, conversationId, null, null, null, null, null, null, null, [], null, null, detail);
}

public enum PhoneWriteOutcome
{
	/// <summary>Stored here and asked of the phone.</summary>
	Queued,

	/// <summary>The change changed nothing; nothing was asked.</summary>
	Unchanged,

	/// <summary>The person has not allowed assistants to add to their archive; nothing was stored or asked.</summary>
	NotAllowed,

	/// <summary>The follow-up or conversation is not in the archive.</summary>
	NotFound,
}

/// <param name="Outcome">What happened.</param>
/// <param name="Item">The row as stored now, when there is one.</param>
/// <param name="RequestId">The request on its way to the phone, when one was made.</param>
public sealed record PhoneWriteResult<T>(PhoneWriteOutcome Outcome, T? Item, Guid? RequestId)
	where T : class;

/// <summary>A follow-up an assistant adds (sync-protocol.md §2.5).</summary>
public sealed record FollowUpDraft(
	string Text,
	string? Quote = null,
	string? Why = null,
	DateTimeOffset? DueAt = null,
	int Priority = 1,
	string? SourceConversationId = null,
	DateTimeOffset? SourceAt = null,
	DateTimeOffset? SourceEndAt = null,
	bool SourceApproximate = false);

/// <summary>
/// A change to a follow-up. A field left null is left alone; <see cref="Settable{T}"/> with a null value clears it.
/// </summary>
public sealed record FollowUpChange
{
	public bool? Done { get; init; }

	/// <summary>When it was done; now when <see cref="Done"/> is true and this is null.</summary>
	public DateTimeOffset? CompletedAt { get; init; }

	public string? Text { get; init; }

	public Settable<DateTimeOffset?>? DueAt { get; init; }

	public Settable<DateTimeOffset?>? SnoozedUntil { get; init; }

	public Settable<DateTimeOffset?>? ArchivedAt { get; init; }
}

/// <summary>A value to set, including null, as distinct from leaving a field alone.</summary>
public readonly record struct Settable<T>(T Value);

/// <summary>A note an assistant adds to a conversation (sync-protocol.md §2.6).</summary>
public sealed record NoteDraft(
	string ConversationId,
	string? Title,
	string? Body,
	IReadOnlyList<NoteCitationDraft>? Citations = null,
	string? TemplateId = null,
	string? Provider = null,
	string? Model = null);

/// <param name="ConversationId">The conversation cited; the note's own when empty.</param>
public sealed record NoteCitationDraft(string? ConversationId, DateTimeOffset At, DateTimeOffset? EndAt = null);

internal enum ClipUploadOutcome
{
	Stored,
	NotFound,
	NotOgg,
}

internal sealed record ClipUpload(ClipUploadOutcome Outcome, Guid? ClipId);
