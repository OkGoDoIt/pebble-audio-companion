using Microsoft.EntityFrameworkCore;
using PebbleAudio.Server.Data;

namespace PebbleAudio.Server.Sync;

/// <summary>Person identity survives phone retention. A rename/deletion updates retained text too.</summary>
public static class ArchivePersonNames
{
	public static async Task NormalizeAsync(ArchiveDbContext db, Guid userId, SyncedRecord record, CancellationToken cancellationToken)
	{
		var ids = record switch
		{
			Transcript transcript => transcript.Items.Select(i => i.PersonId).OfType<string>().Distinct().ToList(),
			Conversation conversation => conversation.People.Select(p => p.PersonId).OfType<string>().Distinct().ToList(),
			_ => [],
		};
		if (ids.Count == 0) { return; }
		var names = await db.People.Where(p => p.UserId == userId && ids.Contains(p.Id)).ToDictionaryAsync(p => p.Id, p => p.Name, cancellationToken);
		var deleted = (await db.SyncItems.Where(s => s.UserId == userId && s.Kind == SyncKind.Person
			&& s.Op == SyncOp.Delete && ids.Contains(s.EntityId)).Select(s => s.EntityId).ToListAsync(cancellationToken)).ToHashSet();
		if (record is Conversation c)
		{
			c.People.RemoveAll(p => p.PersonId is { } id && deleted.Contains(id));
			foreach (var p in c.People) { if (p.PersonId is { } id && names.TryGetValue(id, out var name)) { p.Name = name; } }
		}
		if (record is Transcript t)
		{
			var original = t.Items.Select(i => i.Name).OfType<string>().ToHashSet();
			var changed = false;
			foreach (var item in t.Items)
			{
				if (item.PersonId is not { } id) { continue; }
				if (names.TryGetValue(id, out var name)) { changed |= item.Name != name; item.Name = name; }
				else if (deleted.Contains(id)) { item.PersonId = null; item.Name = null; item.IdentityResolved = true; changed = true; }
			}
			if (changed) { TranscriptSpeakerPatch.Rebuild(t, null, original); }
		}
	}

	public static async Task ApplyAsync(ArchiveDbContext db, Guid userId, string personId, string? name, CancellationToken cancellationToken)
	{
		var ids = await db.Conversations.Where(c => c.UserId == userId && c.People.Any(p => p.PersonId == personId))
			.Select(c => c.Id).Union(db.Transcripts.Where(t => t.UserId == userId && t.Items.Any(i => i.PersonId == personId))
				.Select(t => t.ConversationId)).ToListAsync(cancellationToken);
		// One transcript at a time bounds memory even when a person appears throughout an archive.
		foreach (var id in ids)
		{
			var conversation = await db.Conversations.SingleOrDefaultAsync(c => c.UserId == userId && c.Id == id, cancellationToken);
			var transcript = await db.Transcripts.SingleOrDefaultAsync(t => t.UserId == userId && t.ConversationId == id, cancellationToken);
			var originalNames = transcript?.Items.Select(i => i.Name).OfType<string>().ToHashSet() ?? [];
			if (transcript is not null)
			{
				foreach (var turn in transcript.Items.Where(i => i.Kind == TranscriptItemKind.Turn))
				{
					var namedPeople = conversation?.People.Where(p => p.Name == turn.Name && p.Name is not null)
						.Select(p => p.PersonId).Distinct().ToList() ?? [];
					var legacyMatch = turn.PersonId is null && turn.IdentityResolved != true
						&& namedPeople.Count == 1 && namedPeople[0] == personId;
					if (turn.PersonId != personId && !legacyMatch) { continue; }
					turn.Name = name;
					turn.PersonId = name is null ? null : personId;
					turn.IdentityResolved = true;
				}
			}
			if (conversation is not null)
			{
				if (name is null) { conversation.People.RemoveAll(p => p.PersonId == personId); }
				else { foreach (var person in conversation.People.Where(p => p.PersonId == personId)) { person.Name = name; } }
			}
			if (transcript is not null) { TranscriptSpeakerPatch.Rebuild(transcript, conversation, originalNames); }
			await db.SaveChangesAsync(cancellationToken);
			if (transcript is not null) { db.Entry(transcript).State = EntityState.Detached; }
			if (conversation is not null) { db.Entry(conversation).State = EntityState.Detached; }
		}
	}
}
