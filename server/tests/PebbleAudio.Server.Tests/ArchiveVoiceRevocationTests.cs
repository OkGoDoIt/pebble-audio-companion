using System.Text.Json.Nodes;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using PebbleAudio.Server.Data;

namespace PebbleAudio.Server.Tests;

[Collection(ServerCollection.Name)]
public sealed class ArchiveVoiceRevocationTests(ArchiveServerFactory factory)
{
	private const string Id = "retained-automatic-voice";
	private const string Origin = "local-identity-store";
	private static readonly DateTimeOffset TailAt = Wire.Start.AddMinutes(15);
	private static JsonObject Evidence(long generation = 0, string origin = Origin) => new()
	{
		["originID"] = origin, ["generation"] = generation, ["runID"] = "pass-old",
	};
	private static JsonObject Revocation(string scope, long generation = 1) => new()
	{
		["originID"] = Origin, ["generation"] = generation, ["scope"] = scope,
		["targetID"] = scope == "person" ? "bob" : scope == "run" ? "pass-old" : null,
	};
	private static JsonObject Conversation()
	{
		var c = Wire.Conversation("Retained automatic names", "");
		((JsonArray)c["people"]!).Add(new JsonObject
		{
			["label"] = "2", ["name"] = "Bobunique", ["personId"] = "bob", ["voiceEvidence"] = new JsonArray(Evidence()),
		});
		return c;
	}
	private static JsonObject Range(long generation = 0, string origin = Origin) => new()
	{
		["itemIndex"] = 4, ["segmentId"] = "seg-1791997844787-ed737f28-63", ["startMediaMs"] = 0, ["endMediaMs"] = 8000,
		["at"] = Wire.T(TailAt), ["endAt"] = Wire.T(TailAt.AddSeconds(8)), ["personId"] = "bob", ["name"] = "Bobunique",
		["voiceEvidence"] = new JsonArray(Evidence(generation, origin)),
	};
	private static JsonObject Transcript(long generation = 0, string origin = Origin)
	{
		var t = Wire.Transcript(Id, "Manual opening remains.");
		((JsonArray)t["items"]!).Add(new JsonObject
		{
			["kind"] = "turn", ["at"] = Wire.T(TailAt), ["endAt"] = Wire.T(TailAt.AddSeconds(8)),
			["speaker"] = "2", ["name"] = "Bobunique", ["text"] = "The retained words remain.",
		});
		t["speakerRanges"] = new JsonArray(Range(generation, origin));
		t["text"] = "Alex: Manual opening remains.\nBobunique: The retained words remain.";
		return t;
	}
	private async Task<(Transcript transcript, Conversation conversation)> Read(Guid user)
	{
		await using var scope = factory.Services.CreateAsyncScope();
		var db = scope.ServiceProvider.GetRequiredService<ArchiveDbContext>();
		return (await db.Transcripts.AsNoTracking().SingleAsync(t => t.UserId == user && t.ConversationId == Id),
			await db.Conversations.AsNoTracking().SingleAsync(c => c.UserId == user && c.Id == Id));
	}

	[Theory]
	[InlineData("person")]
	[InlineData("all")]
	[InlineData("run")]
	public async Task Revocation_clears_retained_automatic_names_preserves_manual_and_blocks_delayed_payloads(string scopeKind)
	{
		var user = await factory.CreateUserAsync();
		using var phone = await Phone.LinkAsync(factory, user);
		await phone.BatchAsync(Wire.Item("conversation", Id, 1, payload: Conversation()),
			Wire.Item("transcript", Id, 1, payload: Transcript()), Wire.Item("transcript", Id, 2, op: "expire"));
		var revoke = Wire.Item("voiceRevocation", "revoke-1", 1, payload: Revocation(scopeKind));
		Assert.Single((await phone.BatchAsync(revoke)).GetProperty("accepted").EnumerateArray());
		Assert.Equal("duplicate", (await phone.BatchAsync(revoke)).GetProperty("ignored")[0].GetProperty("reason").GetString());
		var (transcript, conversation) = await Read(user);
		Assert.NotNull(transcript.ExpiredOnPhoneAt);
		Assert.Equal("Alex", transcript.Items[0].Name);
		Assert.Null(transcript.Items[4].Name);
		Assert.Equal(5, transcript.Items.Count);
		Assert.Contains("The retained words remain.", transcript.Text);
		Assert.DoesNotContain(conversation.People, p => p.PersonId == "bob");
		await using (var services = factory.Services.CreateAsyncScope())
		{
			var db = services.ServiceProvider.GetRequiredService<ArchiveDbContext>();
			Assert.Empty(await SyncTests.SearchAsync(db, user, "Bobunique"));
		}
		// A later full upload or a names-only patch captured before Forget cannot undo it.
		await phone.BatchAsync(Wire.Item("conversation", Id, 3, payload: Conversation()),
			Wire.Item("transcript", Id, 3, payload: Transcript()));
		Assert.Null((await Read(user)).transcript.Items[4].Name);
		Assert.DoesNotContain((await Read(user)).conversation.People, p => p.PersonId == "bob");
		await phone.BatchAsync(Wire.Item("transcript", Id, 4, op: "speakerPatch", payload: new JsonObject
		{
			["conversationId"] = Id, ["sourceHash"] = "stale-patch", ["ranges"] = new JsonArray(Range()),
		}));
		Assert.Null((await Read(user)).transcript.Items[4].Name);
		Assert.DoesNotContain((await Read(user)).conversation.People, p => p.PersonId == "bob");
		// Explicit reruns after the decision carry the newer generation, independent of clocks.
		await phone.BatchAsync(Wire.Item("transcript", Id, 5, payload: Transcript(generation: 1)));
		Assert.Equal("Bobunique", (await Read(user)).transcript.Items[4].Name);
	}

	[Fact]
	public async Task Existing_archive_json_without_provenance_remains_manual_and_readable()
	{
		var user = await factory.CreateUserAsync();
		using var phone = await Phone.LinkAsync(factory, user);
		await phone.BatchAsync(Wire.Item("person", "person-alex", 1, payload: Wire.Person("Alex")),
			Wire.Item("conversation", Id, 1, payload: Wire.Conversation("Older archive", "")),
			Wire.Item("transcript", Id, 1, payload: Wire.Transcript(Id, "Manual words from before voice recognition.")));
		await using (var services = factory.Services.CreateAsyncScope())
		{
			var db = services.ServiceProvider.GetRequiredService<ArchiveDbContext>();
			await db.Database.ExecuteSqlInterpolatedAsync($"""
				UPDATE "Transcripts" SET "Items" = (SELECT jsonb_agg(item - 'VoiceEvidence' - 'voiceEvidence')
				FROM jsonb_array_elements("Items") item) WHERE "UserId" = {user};
				UPDATE "Conversations" SET "People" = (SELECT jsonb_agg(item - 'VoiceEvidence' - 'voiceEvidence')
				FROM jsonb_array_elements("People") item) WHERE "UserId" = {user};
				""");
		}
		var old = await Read(user);
		Assert.All(old.transcript.Items, i => Assert.NotNull(i.VoiceEvidence));
		Assert.All(old.conversation.People, p => Assert.NotNull(p.VoiceEvidence));
		var reply = await phone.BatchAsync(Wire.Item("voiceRevocation", "clear", 1, payload: Revocation("all")),
			Wire.Item("person", "person-alex", 2, payload: Wire.Person("Still Manual")));
		Assert.True(reply.GetProperty("rejected").GetArrayLength() == 0, reply.GetRawText());
		Assert.Equal(2, reply.GetProperty("accepted").GetArrayLength());
		Assert.Equal("Still Manual", (await Read(user)).transcript.Items[0].Name);
	}

	[Fact]
	public async Task Revocations_are_account_and_producer_scoped_and_cannot_delete_manual_names()
	{
		var user = await factory.CreateUserAsync();
		using var phone = await Phone.LinkAsync(factory, user);
		using var other = await Phone.LinkAsync(factory, await factory.CreateUserAsync());
		await phone.BatchAsync(Wire.Item("conversation", Id, 1, payload: Conversation()),
			Wire.Item("transcript", Id, 1, payload: Transcript()));
		await other.BatchAsync(Wire.Item("voiceRevocation", "other-account", 1, payload: Revocation("all")));
		Assert.Equal("Bobunique", (await Read(user)).transcript.Items[4].Name);
		await phone.BatchAsync(Wire.Item("transcript", Id, 2, payload: Transcript(origin: "another-local-store")),
			Wire.Item("voiceRevocation", "own-account", 1, payload: Revocation("all")));
		Assert.Equal("Bobunique", (await Read(user)).transcript.Items[4].Name);
		var manual = Transcript();
		((JsonArray)manual["speakerRanges"]!)[0]!["voiceEvidence"] = new JsonArray();
		await phone.BatchAsync(Wire.Item("transcript", Id, 3, payload: manual),
			Wire.Item("voiceRevocation", "forget-bob", 1, payload: Revocation("person", generation: 2)));
		Assert.Equal("Bobunique", (await Read(user)).transcript.Items[4].Name);
		var invalid = await phone.BatchAsync(Wire.Item("voiceRevocation", "invalid", 10, payload: Revocation("all", generation: 0)),
			Wire.Item("voiceRevocation", "own-account", 2, op: "delete"),
			Wire.Item("voiceRevocation", "own-account", 3, payload: Revocation("person", generation: 1)));
		Assert.Equal(3, invalid.GetProperty("rejected").GetArrayLength());
		// Restoring an older backup retires its producer permanently, including generations
		// the restored counter never saw. A fresh local identity store can enroll again.
		await phone.BatchAsync(Wire.Item("transcript", Id, 4, payload: Transcript(generation: 42)),
			Wire.Item("voiceRevocation", "retire-old-backup-origin", 1, payload: Revocation("all", long.MaxValue)));
		Assert.Null((await Read(user)).transcript.Items[4].Name);
		await phone.BatchAsync(Wire.Item("transcript", Id, 5, payload: Transcript(generation: 43)));
		Assert.Null((await Read(user)).transcript.Items[4].Name);
		await phone.BatchAsync(Wire.Item("transcript", Id, 6, payload: Transcript(origin: "fresh-store-after-restore")));
		Assert.Equal("Bobunique", (await Read(user)).transcript.Items[4].Name);
	}
}
