using Microsoft.EntityFrameworkCore;
using PebbleAudio.Server.Data;

namespace PebbleAudio.Server.Sync;

/// <summary>Revocation follows automatic provenance even after the phone has expired its source.</summary>
public static class ArchiveVoiceRevocations
{
	public static bool Valid(VoiceEvidence? evidence) => evidence is not null
		&& !string.IsNullOrWhiteSpace(evidence.OriginID) && evidence.OriginID.Length <= 128
		&& evidence.Generation >= 0 && !string.IsNullOrWhiteSpace(evidence.RunID) && evidence.RunID.Length <= 512;

	public static bool Valid(VoiceRevocation revocation) => !string.IsNullOrWhiteSpace(revocation.OriginID)
		&& revocation.OriginID.Length <= 128 && revocation.Generation > 0
		&& (revocation.Scope == "all" && revocation.TargetID is null
			|| revocation.Scope is "person" or "run" && !string.IsNullOrWhiteSpace(revocation.TargetID) && revocation.TargetID.Length <= 512);

	private static bool Matches(VoiceRevocation revoked, string? personId, IEnumerable<VoiceEvidence> evidence) =>
		evidence.Any(e => e.OriginID == revoked.OriginID && e.Generation < revoked.Generation
			&& (revoked.Scope == "all" || revoked.Scope == "person" && personId == revoked.TargetID
				|| revoked.Scope == "run" && e.RunID == revoked.TargetID));

	public static async Task NormalizeAsync(ArchiveDbContext db, Guid userId, SyncedRecord record, CancellationToken cancellationToken)
	{
		var origins = record switch
		{
			Transcript t => t.Items.SelectMany(i => i.VoiceEvidence).Select(e => e.OriginID).Distinct().ToList(),
			Conversation c => c.People.SelectMany(p => p.VoiceEvidence).Select(e => e.OriginID).Distinct().ToList(),
			_ => [],
		};
		if (origins.Count == 0) { return; }
		var revocations = await db.VoiceRevocations.AsNoTracking()
			.Where(r => r.UserId == userId && origins.Contains(r.OriginID)).ToListAsync(cancellationToken);
		if (record is Conversation conversation)
		{
			conversation.People.RemoveAll(p => revocations.Any(r => Matches(r, p.PersonId, p.VoiceEvidence)));
		}
		if (record is Transcript transcript)
		{
			Clear(transcript, null, revocations);
		}
	}

	public static async Task ApplyAsync(ArchiveDbContext db, Guid userId, VoiceRevocation revocation, CancellationToken cancellationToken)
	{
		var ids = await db.Transcripts.Where(t => t.UserId == userId && t.Items.Any(i =>
			i.VoiceEvidence.Any(e => e.OriginID == revocation.OriginID && e.Generation < revocation.Generation)))
			.Select(t => t.ConversationId).Union(db.Conversations.Where(c => c.UserId == userId && c.People.Any(p =>
				p.VoiceEvidence.Any(e => e.OriginID == revocation.OriginID && e.Generation < revocation.Generation)))
				.Select(c => c.Id)).ToListAsync(cancellationToken);
		foreach (var id in ids)
		{
			var transcript = await db.Transcripts.SingleOrDefaultAsync(t => t.UserId == userId && t.ConversationId == id, cancellationToken);
			var conversation = await db.Conversations.SingleOrDefaultAsync(c => c.UserId == userId && c.Id == id, cancellationToken);
			if (conversation is not null)
			{
				conversation.People.RemoveAll(p => Matches(revocation, p.PersonId, p.VoiceEvidence));
			}
			if (transcript is not null) { Clear(transcript, conversation, [revocation]); }
			await db.SaveChangesAsync(cancellationToken);
			if (transcript is not null) { db.Entry(transcript).State = EntityState.Detached; }
			if (conversation is not null) { db.Entry(conversation).State = EntityState.Detached; }
		}
	}

	private static void Clear(Transcript transcript, Conversation? conversation, IReadOnlyList<VoiceRevocation> revocations)
	{
		var original = transcript.Items.Select(i => i.Name).OfType<string>().ToHashSet();
		var changed = false;
		foreach (var item in transcript.Items)
		{
			if (!revocations.Any(r => Matches(r, item.PersonId, item.VoiceEvidence))) { continue; }
			item.Name = null; item.PersonId = null; item.IdentityResolved = true; item.VoiceEvidence = [];
			changed = true;
		}
		if (changed) { TranscriptSpeakerPatch.Rebuild(transcript, conversation, original); }
	}
}
