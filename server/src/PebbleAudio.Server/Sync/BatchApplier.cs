using System.Text.Json;
using Microsoft.EntityFrameworkCore;
using PebbleAudio.Server.Data;

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
/// </remarks>
public sealed class BatchApplier(
	ArchiveDbContext db,
	ClipStorage storage,
	PhoneRequestService requests,
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

		await using (var transaction = await db.Database.BeginTransactionAsync(cancellationToken))
		{
			await SyncLocks.LockUserAsync(db, userId, cancellationToken);

			foreach (var element in items.EnumerateArray())
			{
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
				if (item.Op == SyncOp.Upsert)
				{
					var parsed = SyncPayloads.Read(item.Kind, item.Id, item.Payload);
					if (parsed.Value is null)
					{
						rejected.Add(new BatchRejected(kind, item.Id, parsed.Error!));
						continue;
					}

					record = parsed.Value;
				}

				var files = new List<string>();
				await transaction.CreateSavepointAsync("item", cancellationToken);
				try
				{
					switch (item.Op)
					{
						case SyncOp.Upsert:
							await UpsertAsync(userId, item, record!, now, cancellationToken);
							break;
						case SyncOp.Delete:
							await DeleteAsync(userId, item.Kind, item.Id, files, cancellationToken);
							break;
						case SyncOp.Expire:
							await ExpireAsync(userId, item.Kind, item.Id, item.ChangedAt, cancellationToken);
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

	private async Task UpsertAsync(Guid userId, Envelope item, SyncedRecord record, DateTimeOffset now, CancellationToken cancellationToken)
	{
		record.UserId = userId;
		record.Version = item.Version;
		record.ChangedAt = item.ChangedAt;
		record.ReceivedAt = now;
		// Sent again, so the phone holds it again.
		record.ExpiredOnPhoneAt = null;

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
			_ => throw new InvalidOperationException($"No table for {record.GetType().Name}."),
		};

		// The payload is the whole entity, so an existing row is replaced column for column. The search vectors are
		// generated columns and follow on their own.
		if (exists)
		{
			db.Update(record);
		}
		else
		{
			db.Add(record);
		}
	}

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
	private async Task DeleteConversationAsync(Guid userId, string id, List<string> files, CancellationToken cancellationToken)
	{
		await db.Conversations.Where(c => c.UserId == userId && c.Id == id).ExecuteDeleteAsync(cancellationToken);
		await db.Transcripts.Where(t => t.UserId == userId && t.ConversationId == id).ExecuteDeleteAsync(cancellationToken);
		await db.Notes.Where(n => n.UserId == userId && n.ConversationId == id).ExecuteDeleteAsync(cancellationToken);
		await db.FollowUps
			.Where(f => f.UserId == userId && f.SourceConversationId == id)
			.ExecuteUpdateAsync(
				s => s
					.SetProperty(f => f.SourceConversationId, (string?)null)
					.SetProperty(f => f.SourceAt, (DateTimeOffset?)null)
					.SetProperty(f => f.SourceEndAt, (DateTimeOffset?)null)
					.SetProperty(f => f.SourceApproximate, false),
				cancellationToken);

		var clips = await db.Clips
			.Where(c => c.UserId == userId && c.ConversationId == id)
			.Select(c => new { c.RequestId, c.Path })
			.ToListAsync(cancellationToken);
		if (clips.Count > 0)
		{
			var requestIds = clips.Select(c => c.RequestId).ToList();
			// Clips go with their requests (cascade).
			await db.Requests.Where(r => r.UserId == userId && requestIds.Contains(r.Id)).ExecuteDeleteAsync(cancellationToken);
			files.AddRange(clips.Select(c => c.Path).OfType<string>());
		}

		await db.Database.ExecuteSqlAsync(
			$"""UPDATE "AiReads" SET "EntityIds" = array_remove("EntityIds", {id}) WHERE "UserId" = {userId} AND {id} = ANY("EntityIds")""",
			cancellationToken);
	}

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

		if (!SyncJson.TryParseInstant(String(element, "changedAt"), out var changedAt))
		{
			error = "changedAt: missing or not an RFC 3339 time";
			return false;
		}

		var payload = element.TryGetProperty("payload", out var payloadElement) ? payloadElement : default;
		if (op == SyncOp.Upsert && payload.ValueKind is JsonValueKind.Undefined or JsonValueKind.Null)
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

/// <param name="Reason"><c>stale</c> (older than what the server holds) or <c>duplicate</c> (the same version).</param>
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
