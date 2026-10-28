using System.Text.Json;
using Microsoft.EntityFrameworkCore;
using PebbleAudio.Server.Data;
using PebbleAudio.Server.Events;
using PebbleAudio.Server.Settings;

namespace PebbleAudio.Server.Sync;

/// <summary>
/// Applies one <c>PUT /sync/batch</c> (sync-protocol.md §3): items in order, inside one transaction, each behind
/// its own savepoint so one item the database refuses does not undo the others.
/// </summary>
/// <remarks>
/// <para>The ledger (<see cref="SyncItem"/>) holds the highest version applied for each (kind, id) and outlives
/// deletes, so an item at or below it is answered as ignored and changes nothing: the phone may resend any
/// batch freely.</para>
/// <para>A transcript needs no conversation to be stored: the two share the conversation's id and are joined when
/// read, so one that arrives first is simply there when its conversation comes.</para>
/// <para>Batches for one user are applied one at a time (a transaction-scoped advisory lock), so a retried batch
/// racing its original cannot leave an older version on top.</para>
/// <para>An upsert dated before the sharing scope is not stored (ignored as <c>outsideScope</c>). A recap whose text
/// changed and a follow-up the phone added are announced to subscribed assistants (MCP Events).</para>
/// </remarks>
public sealed class BatchApplier(
	ArchiveDbContext db,
	ClipStorage storage,
	PhoneRequestService requests,
	SharingScopes scopes,
	IEventPublisher events,
	SettingsService settings,
	TimeProvider time,
	ILogger<BatchApplier> logger)
{
	public async Task<BatchResponse> ApplyAsync(Guid userId, Guid deviceId, JsonElement items, CancellationToken cancellationToken)
	{
		var now = time.GetUtcNow();
		var accepted = new List<BatchItemRef>();
		var ignored = new List<BatchIgnored>();
		var rejected = new List<BatchRejected>();
		var removedFiles = new List<string>();
		var storedConversation = false;
		var recentHours = (await settings.GetAsync(cancellationToken)).EventRecentHours;

		await using (var transaction = await db.Database.BeginTransactionAsync(cancellationToken))
		{
			await SyncLocks.LockUserAsync(db, userId, cancellationToken);
			var scope = await scopes.GetAsync(userId, cancellationToken);

			foreach (var element in items.EnumerateArray())
			{
				var sentKind = element.ValueKind == JsonValueKind.Object ? String(element, "kind") : null;
				if (sentKind == DeviceStatusSync.Kind)
				{
					await ApplyDeviceStatusAsync(userId, deviceId, element, now, transaction, accepted, ignored, rejected, cancellationToken);
					continue;
				}

				// A kind a newer phone knows and this server does not: held, never a failure, so a phone ahead of its
				// server keeps syncing everything else (§3).
				if (!string.IsNullOrEmpty(sentKind) && !WireNames.TryParse(sentKind, out SyncKind _))
				{
					var unknownId = String(element, "id") ?? "";
					var unknownVersion = element.TryGetProperty("version", out var sentVersion) && sentVersion.TryGetInt64(out var number) ? number : 0;
					logger.LogInformation(
						"Sync item of unknown kind {Kind} ({Id}) ignored; the phone is newer than this server.",
						sentKind.Length > 40 ? sentKind[..40] : sentKind,
						unknownId.Length > 80 ? unknownId[..80] : unknownId);
					ignored.Add(new BatchIgnored(sentKind, unknownId, unknownVersion, UnknownKind));
					continue;
				}

				if (!TryReadEnvelope(element, out var item, out var kindText, out var idText, out var error))
				{
					rejected.Add(new BatchRejected(kindText, idText, error));
					continue;
				}

				var kind = item.Kind.ToWire();
				var applied = await db.SyncItems
					.AsNoTracking()
					.Where(s => s.UserId == userId && s.Kind == item.Kind && s.EntityId == item.Id)
					.Select(s => (long?)s.Version)
					.SingleOrDefaultAsync(cancellationToken);
				if (applied is { } held && item.Version <= held)
				{
					ignored.Add(new BatchIgnored(kind, item.Id, item.Version, item.Version < held ? "stale" : "duplicate"));
					continue;
				}

				SyncedRecord? record = null;
				TranscriptSpeakerPatch.Payload? speakerPatch = null;
				if (item.Op == SyncOp.Upsert)
				{
					var parsed = SyncPayloads.Read(item.Kind, item.Id, item.Payload);
					if (parsed.Value is null)
					{
						rejected.Add(new BatchRejected(kind, item.Id, parsed.Error!));
						continue;
					}

					record = parsed.Value;
					if (record is VoiceRevocation revocation)
					{
						var prior = await db.VoiceRevocations.AsNoTracking().SingleOrDefaultAsync(
							r => r.UserId == userId && r.Id == item.Id, cancellationToken);
						if (prior is not null && (prior.OriginID != revocation.OriginID || prior.Generation != revocation.Generation
							|| prior.Scope != revocation.Scope || prior.TargetID != revocation.TargetID))
						{
							rejected.Add(new BatchRejected(kind, item.Id, "payload: voice revocations are immutable"));
							continue;
						}
					}

					// Outside what the person shares: not stored, and not entered in the ledger, so the phone can send
					// the same version again once the scope widens.
					if (await IsOutsideAsync(userId, record, scope, cancellationToken))
					{
						ignored.Add(new BatchIgnored(kind, item.Id, item.Version, OutsideScope));
						continue;
					}
				}
				else if (item.Op == SyncOp.SpeakerPatch)
				{
					if (item.Kind != SyncKind.Transcript || !TranscriptSpeakerPatch.TryRead(item.Payload, item.Id, out speakerPatch, out _))
					{
						rejected.Add(new BatchRejected(kind, item.Id, "payload: invalid speaker patch"));
						continue;
					}
					record = await db.Transcripts.AsNoTracking().SingleOrDefaultAsync(t => t.UserId == userId && t.ConversationId == item.Id, cancellationToken);
					if (record is null)
					{
						rejected.Add(new BatchRejected(kind, item.Id, "payload: transcript to patch is missing"));
						continue;
					}
					if (await IsOutsideAsync(userId, record, scope, cancellationToken))
					{
						ignored.Add(new BatchIgnored(kind, item.Id, item.Version, OutsideScope));
						continue;
					}
				}

				var files = new List<string>();
				await transaction.CreateSavepointAsync("item", cancellationToken);
				try
				{
					Upserted? upserted = null;
					switch (item.Op)
					{
						case SyncOp.Upsert:
							upserted = await UpsertAsync(userId, item, record!, now, cancellationToken);
							break;
						case SyncOp.Delete:
							await DeleteAsync(userId, item.Kind, item.Id, files, cancellationToken);
							break;
						case SyncOp.Expire:
							await ExpireAsync(userId, item.Kind, item.Id, item.ChangedAt, cancellationToken);
							break;
						case SyncOp.SpeakerPatch:
							var transcript = (Transcript)record!;
							var conversation = await db.Conversations.SingleOrDefaultAsync(c => c.UserId == userId && c.Id == item.Id, cancellationToken);
							TranscriptSpeakerPatch.Apply(transcript, conversation, speakerPatch!);
							await ArchiveVoiceRevocations.NormalizeAsync(db, userId, transcript, cancellationToken);
							if (conversation is not null) { await ArchiveVoiceRevocations.NormalizeAsync(db, userId, conversation, cancellationToken); }
							await ArchivePersonNames.NormalizeAsync(db, userId, transcript, cancellationToken);
							if (conversation is not null) { await ArchivePersonNames.NormalizeAsync(db, userId, conversation, cancellationToken); }
							transcript.Version = item.Version;
							transcript.ChangedAt = item.ChangedAt;
							transcript.ReceivedAt = now;
							db.Update(transcript);
							break;
					}

					var ledger = new SyncItem
					{
						UserId = userId,
						Kind = item.Kind,
						EntityId = item.Id,
						Version = item.Version,
						Op = item.Op,
						AppliedAt = now,
						DeviceId = deviceId,
					};
					if (applied is null)
					{
						db.SyncItems.Add(ledger);
					}
					else
					{
						db.SyncItems.Update(ledger);
					}

					await db.SaveChangesAsync(cancellationToken);
					if (upserted is { } done)
					{
						// Inside the item's savepoint, so an event is queued exactly when its change is kept.
						await AnnounceAsync(done, now, recentHours, cancellationToken);
						storedConversation |= done.Record is Conversation;
					}

					await transaction.ReleaseSavepointAsync("item", cancellationToken);
					accepted.Add(new BatchItemRef(kind, item.Id, item.Version));
					removedFiles.AddRange(files);
				}
				catch (Exception ex) when (ex is not OperationCanceledException)
				{
					await transaction.RollbackToSavepointAsync("item", cancellationToken);
					logger.LogWarning(ex, "Sync item {Kind} {Id} v{Version} could not be stored.", kind, item.Id, item.Version);
					rejected.Add(new BatchRejected(kind, item.Id, "server: could not store it"));
				}
				finally
				{
					// Transcripts can be a megabyte each; nothing stays tracked between items.
					db.ChangeTracker.Clear();
				}
			}

			await db.Devices
				.Where(d => d.Id == deviceId)
				.ExecuteUpdateAsync(s => s.SetProperty(d => d.LastBatchAt, now), cancellationToken);
			if (storedConversation)
			{
				await scopes.FollowLatestTimeZoneAsync(userId, cancellationToken);
			}

			await transaction.CommitAsync(cancellationToken);
		}

		// Files go only once the rows that pointed at them are gone for good.
		foreach (var file in removedFiles)
		{
			storage.Delete(file);
		}

		var pending = await requests.CountPendingAsync(userId, cancellationToken);
		return new BatchResponse(now, accepted, ignored, rejected, pending);
	}

	private async Task<Upserted> UpsertAsync(Guid userId, Envelope item, SyncedRecord record, DateTimeOffset now, CancellationToken cancellationToken)
	{
		await ArchiveVoiceRevocations.NormalizeAsync(db, userId, record, cancellationToken);
		await ArchivePersonNames.NormalizeAsync(db, userId, record, cancellationToken);
		record.UserId = userId;
		record.Version = item.Version;
		record.ChangedAt = item.ChangedAt;
		record.ReceivedAt = now;
		// Sent again, so the phone holds it again.
		record.ExpiredOnPhoneAt = null;

		var previousRecap = record is Recap recap
			? await db.Recaps
				.AsNoTracking()
				.Where(r => r.UserId == userId && r.DayKey == recap.DayKey)
				.Select(r => new RecapText(r.Headline, r.LineSummary, r.ShortText, r.Text))
				.SingleOrDefaultAsync(cancellationToken)
			: null;

		var previousStage = record is FollowUp incoming
			? await db.FollowUps
				.AsNoTracking()
				.Where(f => f.UserId == userId && f.Id == incoming.Id)
				.Select(f => (FollowUpStage?)f.Stage)
				.SingleOrDefaultAsync(cancellationToken)
			: null;

		var exists = record switch
		{
			Conversation c => await db.Conversations.AnyAsync(r => r.UserId == userId && r.Id == c.Id, cancellationToken),
			Transcript t => await db.Transcripts.AnyAsync(r => r.UserId == userId && r.ConversationId == t.ConversationId, cancellationToken),
			Recap r => await db.Recaps.AnyAsync(x => x.UserId == userId && x.DayKey == r.DayKey, cancellationToken),
			Brief b => await db.Briefs.AnyAsync(r => r.UserId == userId && r.PeriodKey == b.PeriodKey, cancellationToken),
			FollowUp f => await db.FollowUps.AnyAsync(r => r.UserId == userId && r.Id == f.Id, cancellationToken),
			Note n => await db.Notes.AnyAsync(r => r.UserId == userId && r.Id == n.Id, cancellationToken),
			Person p => await db.People.AnyAsync(r => r.UserId == userId && r.Id == p.Id, cancellationToken),
			CoverageDay c => await db.CoverageDays.AnyAsync(r => r.UserId == userId && r.DayKey == c.DayKey, cancellationToken),
			VoiceRevocation r => await db.VoiceRevocations.AnyAsync(v => v.UserId == userId && v.Id == r.Id, cancellationToken),
			_ => throw new InvalidOperationException($"No table for {record.GetType().Name}."),
		};

		// The payload is the whole entity, so an existing row is replaced column for column. The search vectors are
		// generated columns and follow on their own.
		if (record is Person namedPerson)
		{
			await ArchivePersonNames.ApplyAsync(db, userId, namedPerson.Id, namedPerson.Name, cancellationToken);
		}
		if (record is VoiceRevocation revoked)
		{
			await ArchiveVoiceRevocations.ApplyAsync(db, userId, revoked, cancellationToken);
		}
		if (exists)
		{
			db.Update(record);
		}
		else
		{
			db.Add(record);
		}

		return new Upserted(record, exists, previousRecap, previousStage);
	}

	/// <summary>
	/// Tells subscribed assistants about a day's recap whose text is new or changed, and a reminder the phone has just
	/// added: a new one, or a follow-up the person has just said yes to. A follow-up still waiting for review is not
	/// announced: nothing is on the person's list until they say yes. A recap for an older day, or a reminder that
	/// became one before the <c>EventRecentHours</c> setting, is history the phone is catching up on, not news, and
	/// wakes no one.
	/// </summary>
	private async Task AnnounceAsync(Upserted upserted, DateTimeOffset now, int recentHours, CancellationToken cancellationToken)
	{
		var since = now - TimeSpan.FromHours(recentHours);
		switch (upserted.Record)
		{
			case Recap recap when upserted.PreviousRecap != new RecapText(recap.Headline, recap.LineSummary, recap.ShortText, recap.Text) &&
				recap.DayKey >= LogicalDays.Of(since, LogicalDays.Zone(recap.TimeZone)):
				await events.DayRecapReadyAsync(recap, cancellationToken);
				break;
			case FollowUp followUp when followUp.Stage == FollowUpStage.Reminder && upserted.PreviousStage != FollowUpStage.Reminder &&
				(upserted.Existed ? followUp.ChangedAt : followUp.CreatedAt) >= since:
				await events.FollowUpCreatedAsync(followUp, cancellationToken);
				break;
		}
	}

	/// <summary>
	/// True when an upsert is dated before the sharing scope (sync-protocol.md §5): a conversation by its start, a
	/// transcript and a note by their conversation (a transcript without one by its first item, a note by when it was
	/// written), a recap and coverage by day, a brief by its last day, a follow-up by its source time or creation.
	/// </summary>
	private async Task<bool> IsOutsideAsync(Guid userId, SyncedRecord record, AccountScope scope, CancellationToken cancellationToken)
	{
		if (scope.From is null)
		{
			return false;
		}

		switch (record)
		{
			case Conversation c:
				return !scope.Holds(c.StartedAt);
			case Transcript t:
				var started = await ConversationStartAsync(userId, t.ConversationId, cancellationToken);
				return started is { } at ? !scope.Holds(at) : t.Items.Count > 0 && !scope.Holds(t.Items.Min(i => i.At));
			case Note n:
				var noteStarted = n.ConversationId is { } conversationId ? await ConversationStartAsync(userId, conversationId, cancellationToken) : null;
				return !scope.Holds(noteStarted ?? n.CreatedAt);
			case Recap r:
				return !scope.HoldsDay(r.DayKey);
			case CoverageDay c:
				return !scope.HoldsDay(c.DayKey);
			case Brief b:
				return !scope.HoldsDay(b.EndDay);
			case FollowUp f:
				return !scope.Holds(f.SourceAt ?? f.CreatedAt);
			default:
				return false;
		}
	}

	private Task<DateTimeOffset?> ConversationStartAsync(Guid userId, string conversationId, CancellationToken cancellationToken) =>
		db.Conversations
			.AsNoTracking()
			.Where(c => c.UserId == userId && c.Id == conversationId)
			.Select(c => (DateTimeOffset?)c.StartedAt)
			.SingleOrDefaultAsync(cancellationToken);

	/// <summary>What ignoring an item outside the sharing scope is called in the batch answer.</summary>
	public const string OutsideScope = "outsideScope";

	/// <summary>What ignoring an item of a kind this server does not know is called in the batch answer.</summary>
	public const string UnknownKind = "unknownKind";

	/// <summary>
	/// Stores the phone's report about its watch (§2.8) under the phone the token names, whatever id the item carries:
	/// one row per phone, replaced by each newer version. It has its own savepoint, like every item.
	/// </summary>
	private async Task ApplyDeviceStatusAsync(
		Guid userId,
		Guid deviceId,
		JsonElement element,
		DateTimeOffset now,
		Microsoft.EntityFrameworkCore.Storage.IDbContextTransaction transaction,
		List<BatchItemRef> accepted,
		List<BatchIgnored> ignored,
		List<BatchRejected> rejected,
		CancellationToken cancellationToken)
	{
		const string kind = DeviceStatusSync.Kind;
		var id = String(element, "id") ?? "";
		if (id.Length == 0)
		{
			rejected.Add(new BatchRejected(kind, id, "id: missing"));
			return;
		}

		if (!element.TryGetProperty("version", out var versionElement) || !versionElement.TryGetInt64(out var version))
		{
			rejected.Add(new BatchRejected(kind, id, "version: missing"));
			return;
		}

		var op = String(element, "op");
		if (op != SyncOp.Upsert.ToWire())
		{
			rejected.Add(new BatchRejected(kind, id, op is null ? "op: missing" : "op: device status is only upserted"));
			return;
		}

		var parsed = DeviceStatusSync.Read(element.TryGetProperty("payload", out var payload) ? payload : default);
		if (parsed.Value is not { } status)
		{
			rejected.Add(new BatchRejected(kind, id, payload.ValueKind is JsonValueKind.Undefined or JsonValueKind.Null ? "payload: missing" : parsed.Error!));
			return;
		}

		var held = await db.DeviceStatuses
			.AsNoTracking()
			.Where(s => s.DeviceId == deviceId)
			.Select(s => (long?)s.Version)
			.SingleOrDefaultAsync(cancellationToken);
		if (held is { } heldVersion && version <= heldVersion)
		{
			ignored.Add(new BatchIgnored(kind, id, version, version < heldVersion ? "stale" : "duplicate"));
			return;
		}

		status.DeviceId = deviceId;
		status.UserId = userId;
		status.Version = version;
		status.ReceivedAt = now;
		await transaction.CreateSavepointAsync("item", cancellationToken);
		try
		{
			if (held is null)
			{
				db.DeviceStatuses.Add(status);
			}
			else
			{
				db.DeviceStatuses.Update(status);
			}

			await db.SaveChangesAsync(cancellationToken);
			await transaction.ReleaseSavepointAsync("item", cancellationToken);
			accepted.Add(new BatchItemRef(kind, id, version));
		}
		catch (Exception ex) when (ex is not OperationCanceledException)
		{
			await transaction.RollbackToSavepointAsync("item", cancellationToken);
			logger.LogWarning(ex, "Device status v{Version} could not be stored.", version);
			rejected.Add(new BatchRejected(kind, id, "server: could not store it"));
		}
		finally
		{
			db.ChangeTracker.Clear();
		}
	}

	private sealed record RecapText(string? Headline, string? LineSummary, string? ShortText, string? Text);

	/// <param name="Record">The row as stored.</param>
	/// <param name="Existed">Whether it replaced an earlier version.</param>
	/// <param name="PreviousRecap">For a recap, the text it replaced.</param>
	/// <param name="PreviousStage">For a follow-up, the stage it had before.</param>
	private sealed record Upserted(SyncedRecord Record, bool Existed, RecapText? PreviousRecap, FollowUpStage? PreviousStage);

	/// <summary>
	/// The person deleted it on the phone: the server deletes it and everything it derived from it.
	/// </summary>
	private async Task DeleteAsync(Guid userId, SyncKind kind, string id, List<string> files, CancellationToken cancellationToken)
	{
		switch (kind)
		{
			case SyncKind.Conversation:
				await DeleteConversationAsync(userId, id, files, cancellationToken);
				break;
			case SyncKind.Transcript:
				await db.Transcripts.Where(t => t.UserId == userId && t.ConversationId == id).ExecuteDeleteAsync(cancellationToken);
				break;
			case SyncKind.Recap:
				if (SyncJson.TryParseDay(id, out var recapDay))
				{
					await db.Recaps.Where(r => r.UserId == userId && r.DayKey == recapDay).ExecuteDeleteAsync(cancellationToken);
				}

				break;
			case SyncKind.Brief:
				await db.Briefs.Where(b => b.UserId == userId && b.PeriodKey == id).ExecuteDeleteAsync(cancellationToken);
				break;
			case SyncKind.FollowUp:
				await db.FollowUps.Where(f => f.UserId == userId && f.Id == id).ExecuteDeleteAsync(cancellationToken);
				break;
			case SyncKind.Note:
				await db.Notes.Where(n => n.UserId == userId && n.Id == id).ExecuteDeleteAsync(cancellationToken);
				break;
			case SyncKind.Person:
				await ArchivePersonNames.ApplyAsync(db, userId, id, null, cancellationToken);
				await db.People.Where(p => p.UserId == userId && p.Id == id).ExecuteDeleteAsync(cancellationToken);
				break;
			case SyncKind.Coverage:
				if (SyncJson.TryParseDay(id, out var coverageDay))
				{
					await db.CoverageDays.Where(c => c.UserId == userId && c.DayKey == coverageDay).ExecuteDeleteAsync(cancellationToken);
				}

				break;
		}
	}

	/// <summary>
	/// A conversation goes with its transcript, its notes, its clips and their requests, and its place in the
	/// AI-read log. Follow-ups said in it keep their text and lose the link back.
	/// </summary>
	private Task DeleteConversationAsync(Guid userId, string id, List<string> files, CancellationToken cancellationToken) =>
		ArchiveDeletes.ConversationsAsync(db, userId, [id], files, cancellationToken);

	/// <summary>
	/// The phone's retention aged it out: the server keeps it and notes that the phone no longer has it.
	/// </summary>
	private async Task ExpireAsync(Guid userId, SyncKind kind, string id, DateTimeOffset at, CancellationToken cancellationToken)
	{
		switch (kind)
		{
			case SyncKind.Conversation:
				await Expire(db.Conversations.Where(c => c.UserId == userId && c.Id == id), at, cancellationToken);
				break;
			case SyncKind.Transcript:
				await Expire(db.Transcripts.Where(t => t.UserId == userId && t.ConversationId == id), at, cancellationToken);
				break;
			case SyncKind.Recap:
				if (SyncJson.TryParseDay(id, out var recapDay))
				{
					await Expire(db.Recaps.Where(r => r.UserId == userId && r.DayKey == recapDay), at, cancellationToken);
				}

				break;
			case SyncKind.Brief:
				await Expire(db.Briefs.Where(b => b.UserId == userId && b.PeriodKey == id), at, cancellationToken);
				break;
			case SyncKind.FollowUp:
				await Expire(db.FollowUps.Where(f => f.UserId == userId && f.Id == id), at, cancellationToken);
				break;
			case SyncKind.Note:
				await Expire(db.Notes.Where(n => n.UserId == userId && n.Id == id), at, cancellationToken);
				break;
			case SyncKind.Person:
				await Expire(db.People.Where(p => p.UserId == userId && p.Id == id), at, cancellationToken);
				break;
			case SyncKind.Coverage:
				if (SyncJson.TryParseDay(id, out var coverageDay))
				{
					await Expire(db.CoverageDays.Where(c => c.UserId == userId && c.DayKey == coverageDay), at, cancellationToken);
				}

				break;
		}
	}

	private static Task<int> Expire<T>(IQueryable<T> rows, DateTimeOffset at, CancellationToken cancellationToken)
		where T : SyncedRecord =>
		rows.ExecuteUpdateAsync(s => s.SetProperty(r => r.ExpiredOnPhoneAt, at), cancellationToken);

	private static bool TryReadEnvelope(JsonElement element, out Envelope item, out string kindText, out string idText, out string error)
	{
		item = default;
		kindText = "";
		idText = "";
		error = "";
		if (element.ValueKind != JsonValueKind.Object)
		{
			error = "item: not an object";
			return false;
		}

		kindText = String(element, "kind") ?? "";
		idText = String(element, "id") ?? "";
		if (!WireNames.TryParse(kindText, out SyncKind kind))
		{
			error = kindText.Length == 0 ? "kind: missing" : $"kind: '{kindText}' is not known";
			return false;
		}

		if (idText.Length == 0)
		{
			error = "id: missing";
			return false;
		}

		if (!element.TryGetProperty("version", out var versionElement) || !versionElement.TryGetInt64(out var version))
		{
			error = "version: missing";
			return false;
		}

		var opText = String(element, "op");
		if (!WireNames.TryParse(opText, out SyncOp op))
		{
			error = opText is null ? "op: missing" : $"op: '{opText}' is not known";
			return false;
		}
		if (kind == SyncKind.VoiceRevocation && op != SyncOp.Upsert)
		{
			error = "op: voice revocations are permanent upserts";
			return false;
		}

		if (!SyncJson.TryParseInstant(String(element, "changedAt"), out var changedAt))
		{
			error = "changedAt: missing or not an RFC 3339 time";
			return false;
		}

		var payload = element.TryGetProperty("payload", out var payloadElement) ? payloadElement : default;
		if (op is SyncOp.Upsert or SyncOp.SpeakerPatch && payload.ValueKind is JsonValueKind.Undefined or JsonValueKind.Null)
		{
			error = "payload: missing";
			return false;
		}

		item = new Envelope(kind, idText, version, op, changedAt, payload);
		return true;
	}

	private static string? String(JsonElement element, string name) =>
		element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

	private readonly record struct Envelope(
		SyncKind Kind,
		string Id,
		long Version,
		SyncOp Op,
		DateTimeOffset ChangedAt,
		JsonElement Payload);
}

/// <summary>The answer to <c>PUT /sync/batch</c> (§3).</summary>
public sealed record BatchResponse(
	DateTimeOffset ServerTime,
	IReadOnlyList<BatchItemRef> Accepted,
	IReadOnlyList<BatchIgnored> Ignored,
	IReadOnlyList<BatchRejected> Rejected,
	int PendingRequests);

public sealed record BatchItemRef(string Kind, string Id, long Version);

/// <param name="Reason"><c>stale</c> (older than what the server holds), <c>duplicate</c> (the same version),
/// <c>outsideScope</c> (dated before the sharing scope), or <c>unknownKind</c> (a kind this server does not know).</param>
public sealed record BatchIgnored(string Kind, string Id, long Version, string Reason);

public sealed record BatchRejected(string Kind, string Id, string Reason);

internal static class SyncLocks
{
	/// <summary>
	/// Serializes the writes of one user's sync (batches and wipes) until the current transaction ends.
	/// </summary>
	public static Task LockUserAsync(ArchiveDbContext db, Guid userId, CancellationToken cancellationToken) =>
		db.Database.ExecuteSqlAsync($"SELECT pg_advisory_xact_lock(hashtextextended({userId.ToString()}, 7))", cancellationToken);
}
