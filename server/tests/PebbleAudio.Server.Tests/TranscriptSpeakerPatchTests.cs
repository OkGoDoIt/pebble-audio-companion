using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using PebbleAudio.Server.Data;
using PebbleAudio.Server.Sync;

namespace PebbleAudio.Server.Tests;

[Collection(ServerCollection.Name)]
public sealed class TranscriptSpeakerPatchTests(ArchiveServerFactory factory)
{
	private const string Id = "retained-voice-conversation";
	private const string Tail = "seg-1791997844787-ed737f28-63";
	private static readonly DateTimeOffset TailAt = Wire.Start.AddMinutes(15);

	private static JsonObject Range(string? name, string? personId, long start = 0, long end = 8000) => new()
	{
		["segmentId"] = Tail, ["startMediaMs"] = start, ["endMediaMs"] = end,
		["at"] = Wire.T(TailAt.AddMilliseconds(start)), ["endAt"] = Wire.T(TailAt.AddMilliseconds(end)),
		["name"] = name, ["personId"] = personId,
	};
	private static JsonObject Patch(params JsonObject[] ranges) => new()
	{
		["conversationId"] = Id, ["sourceHash"] = "identity-revision-2", ["ranges"] = new JsonArray(ranges),
	};
	private static JsonObject Transcript(bool anchored = false)
	{
		var transcript = Wire.Transcript(Id, "The retained opening must remain.");
		var turns = (JsonArray)transcript["items"]!;
		turns.Add(new JsonObject
		{
			["kind"] = "turn", ["at"] = Wire.T(TailAt), ["endAt"] = Wire.T(TailAt.AddSeconds(8)),
			["name"] = "Alex", ["speaker"] = "1", ["text"] = "The surviving tail also remains.", ["confidence"] = 0.9,
		});
		transcript["text"] = "Alex: The retained opening must remain.\nAlex: The surviving tail also remains.";
		if (anchored)
		{
			var range = Range("Alex", "person-alex");
			range["itemIndex"] = 4;
			transcript["speakerRanges"] = new JsonArray(range);
		}
		return transcript;
	}

	[Fact]
	public async Task Tail_patch_preserves_words_prefix_markers_and_expiry_updates_search_and_is_idempotent()
	{
		var user = await factory.CreateUserAsync();
		using var phone = await Phone.LinkAsync(factory, user);
		var original = Transcript(); // Existing archives have no media anchors.
		await phone.BatchAsync(Wire.Item("conversation", Id, 1, payload: Wire.Conversation("A retained conversation", "")),
			Wire.Item("transcript", Id, 1, payload: original), Wire.Item("transcript", Id, 2, op: "expire"));
		var patch = Wire.Item("transcript", Id, 3, op: "speakerPatch", payload: Patch(Range("Zaphira", "person-z")));
		Assert.Single((await phone.BatchAsync(patch)).GetProperty("accepted").EnumerateArray());
		Assert.Equal("duplicate", (await phone.BatchAsync(patch)).GetProperty("ignored")[0].GetProperty("reason").GetString());
		Assert.Equal("stale", (await phone.BatchAsync(Wire.Item("transcript", Id, 1, payload: (JsonObject)original.DeepClone())))
			.GetProperty("ignored")[0].GetProperty("reason").GetString());

		await using var scope = factory.Services.CreateAsyncScope();
		var db = scope.ServiceProvider.GetRequiredService<ArchiveDbContext>();
		var transcript = await db.Transcripts.AsNoTracking().SingleAsync(t => t.UserId == user && t.ConversationId == Id);
		Assert.Equal(5, transcript.Items.Count);
		Assert.Equal("Alex", transcript.Items[0].Name);
		Assert.Equal("Zaphira", transcript.Items[4].Name);
		Assert.Equal("The surviving tail also remains.", transcript.Items[4].Text);
		Assert.Equal(TranscriptItemKind.Lost, transcript.Items[1].Kind);
		Assert.NotNull(transcript.ExpiredOnPhoneAt);
		Assert.Equal("soniox", transcript.Provider);
		Assert.Contains("The retained opening must remain.", transcript.Text);
		Assert.Contains(Id, await SyncTests.SearchAsync(db, user, "Zaphira"));
		var conversation = await db.Conversations.AsNoTracking().SingleAsync(c => c.UserId == user && c.Id == Id);
		Assert.Equal(2, conversation.Pieces.Count);
		Assert.Equal(["Alex", "Zaphira"], conversation.People.Select(p => p.Name));

		await phone.BatchAsync(Wire.Item("transcript", Id, 4, op: "speakerPatch", payload: Patch(Range(null, null))));
		transcript = await db.Transcripts.AsNoTracking().SingleAsync(t => t.UserId == user && t.ConversationId == Id);
		Assert.Null(transcript.Items[4].Name);
		Assert.True(transcript.Items[4].IdentityResolved); // viewer must not restore prefix label's name
		Assert.Empty(await SyncTests.SearchAsync(db, user, "Zaphira"));
	}

	[Fact]
	public async Task Anchors_disambiguate_media_and_partial_or_conflicting_decisions_abstain()
	{
		var user = await factory.CreateUserAsync();
		using var phone = await Phone.LinkAsync(factory, user);
		await phone.BatchAsync(Wire.Item("conversation", Id, 1, payload: Wire.Conversation("Anchored", "")),
			Wire.Item("transcript", Id, 1, payload: Transcript(anchored: true)));
		await phone.BatchAsync(Wire.Item("transcript", Id, 2, op: "speakerPatch", payload: Patch(Range("Sam", "sam", end: 4000))));
		await using var scope = factory.Services.CreateAsyncScope();
		var db = scope.ServiceProvider.GetRequiredService<ArchiveDbContext>();
		var transcript = await db.Transcripts.AsNoTracking().SingleAsync(t => t.UserId == user && t.ConversationId == Id);
		Assert.Null(transcript.Items[4].Name);
		Assert.Equal(Tail, transcript.Items[4].SegmentId);
		Assert.Equal(8000, transcript.Items[4].EndMediaMs);
		await phone.BatchAsync(Wire.Item("transcript", Id, 3, op: "speakerPatch", payload: Patch(
			Range("Sam", "sam", end: 4000), Range("Dana", "dana", start: 4000))));
		transcript = await db.Transcripts.AsNoTracking().SingleAsync(t => t.UserId == user && t.ConversationId == Id);
		Assert.Null(transcript.Items[4].Name);
		Assert.Equal("Alex", transcript.Items[0].Name);
	}

	[Fact]
	public async Task Patch_is_account_scoped_rejects_missing_invalid_or_wrong_kind_and_never_creates_words()
	{
		var user = await factory.CreateUserAsync();
		using var phone = await Phone.LinkAsync(factory, user);
		using var other = await Phone.LinkAsync(factory, await factory.CreateUserAsync());
		await phone.BatchAsync(Wire.Item("conversation", Id, 1, payload: Wire.Conversation("Private", "")),
			Wire.Item("transcript", Id, 1, payload: Transcript()));
		Assert.Single((await other.BatchAsync(Wire.Item("transcript", Id, 100, op: "speakerPatch", payload: Patch(Range("Stolen", "x")))))
			.GetProperty("rejected").EnumerateArray());
		var invalid = Range("Invalid", "x", start: -1);
		var rejected = await phone.BatchAsync(Wire.Item("transcript", Id, 100, op: "speakerPatch", payload: Patch(invalid)),
			Wire.Item("conversation", Id, 100, op: "speakerPatch", payload: Patch(Range("Invalid", "x"))));
		Assert.Equal(2, rejected.GetProperty("rejected").GetArrayLength());
		// Rejected patches do not consume the transcript ledger version.
		Assert.Single((await phone.BatchAsync(Wire.Item("transcript", Id, 2, op: "speakerPatch", payload: Patch(Range("Sam", "sam")))))
			.GetProperty("accepted").EnumerateArray());
		await using var scope = factory.Services.CreateAsyncScope();
		var db = scope.ServiceProvider.GetRequiredService<ArchiveDbContext>();
		Assert.False(await db.Transcripts.AnyAsync(t => t.UserId == other.UserId));
		var transcript = await db.Transcripts.AsNoTracking().SingleAsync(t => t.UserId == user && t.ConversationId == Id);
		Assert.Equal("Sam", transcript.Items[4].Name);
	}

	[Fact]
	public async Task Person_rename_and_delete_reach_retained_history_and_stale_payloads_cannot_restore_them()
	{
		var user = await factory.CreateUserAsync();
		using var phone = await Phone.LinkAsync(factory, user);
		await phone.BatchAsync(Wire.Item("person", "person-alex", 1, payload: Wire.Person("Alex")),
			Wire.Item("conversation", Id, 1, payload: Wire.Conversation("Retained names", "")),
			Wire.Item("transcript", Id, 1, payload: Transcript(anchored: true)),
			Wire.Item("transcript", Id, 2, op: "expire"));
		Assert.Single((await phone.BatchAsync(Wire.Item("person", "person-alex", 2, payload: Wire.Person("Renamedunique"))))
			.GetProperty("accepted").EnumerateArray());
		await using var scope = factory.Services.CreateAsyncScope();
		var db = scope.ServiceProvider.GetRequiredService<ArchiveDbContext>();
		var transcript = await db.Transcripts.AsNoTracking().SingleAsync(t => t.UserId == user && t.ConversationId == Id);
		Assert.All(transcript.Items.Where(i => i.Kind == TranscriptItemKind.Turn), i => Assert.Equal("Renamedunique", i.Name));
		Assert.NotNull(transcript.ExpiredOnPhoneAt);
		Assert.Contains(Id, await SyncTests.SearchAsync(db, user, "Renamedunique"));
		await phone.BatchAsync(Wire.Item("person", "person-alex", 3, op: "delete"));
		await phone.BatchAsync(Wire.Item("transcript", Id, 4, op: "speakerPatch", payload: Patch(Range("Alex", "person-alex"))));
		transcript = await db.Transcripts.AsNoTracking().SingleAsync(t => t.UserId == user && t.ConversationId == Id);
		Assert.All(transcript.Items.Where(i => i.Kind == TranscriptItemKind.Turn), i => Assert.Null(i.Name));
		Assert.Empty(await SyncTests.SearchAsync(db, user, "Renamedunique"));
		Assert.Contains("The retained opening must remain.", transcript.Text);
	}
}
