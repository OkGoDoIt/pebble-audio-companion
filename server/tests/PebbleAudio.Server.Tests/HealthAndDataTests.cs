using System.Net;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using PebbleAudio.Server.Data;

namespace PebbleAudio.Server.Tests;

[Collection(ServerCollection.Name)]
public sealed class HealthAndDataTests(ArchiveServerFactory factory)
{
	[Fact]
	public async Task Healthz_answers_200_when_the_database_answers()
	{
		using var client = factory.CreateClient();

		var response = await client.GetAsync("/healthz");

		Assert.Equal(HttpStatusCode.OK, response.StatusCode);
		Assert.Equal("Healthy", await response.Content.ReadAsStringAsync());
	}

	[Fact]
	public async Task Conversations_round_trip_their_json_and_are_found_by_title_tags_and_transcript()
	{
		var userId = await factory.CreateUserAsync();
		var otherUserId = await factory.CreateUserAsync();
		var id = $"conv-seg-{Guid.NewGuid():N}";

		await using (var scope = factory.Services.CreateAsyncScope())
		{
			var db = scope.ServiceProvider.GetRequiredService<ArchiveDbContext>();
			db.Conversations.Add(TestData.Conversation(userId, id, "Stale audiobook playback on the watch", "Pebble", "firmware"));
			db.Conversations.Add(TestData.Conversation(otherUserId, id, "Someone else's audiobook talk", "firmware"));
			db.Transcripts.Add(new Transcript
			{
				UserId = userId,
				ConversationId = id,
				Version = 1_791_999_180_000,
				ChangedAt = DateTimeOffset.UtcNow,
				ReceivedAt = DateTimeOffset.UtcNow,
				Provider = "soniox",
				Text = "Roger: BookPlayer keeps publishing a playback rate of one while paused.",
				CharCount = 72,
				Items =
				[
					new TranscriptItem { Kind = TranscriptItemKind.Turn, At = DateTimeOffset.UtcNow, Speaker = "1", Name = "Roger", Text = "BookPlayer keeps publishing a playback rate of one while paused.", Confidence = 0.93 },
					new TranscriptItem { Kind = TranscriptItemKind.Quiet, At = DateTimeOffset.UtcNow },
					new TranscriptItem { Kind = TranscriptItemKind.Masked, At = DateTimeOffset.UtcNow, Descriptor = "music" },
				],
			});
			await db.SaveChangesAsync();
		}

		await using (var scope = factory.Services.CreateAsyncScope())
		{
			var db = scope.ServiceProvider.GetRequiredService<ArchiveDbContext>();
			var stored = await db.Conversations.AsNoTracking().SingleAsync(c => c.UserId == userId && c.Id == id);
			Assert.Equal(["Pebble", "firmware"], stored.Tags);
			Assert.Equal([GapKind.Lost, GapKind.Quiet], stored.Gaps.Select(g => g.Kind));
			Assert.Equal("watch", stored.Gaps[0].Origin);
			Assert.Equal(83_010, Assert.Single(stored.Pieces).StartMediaMs);
			Assert.Equal(TimeSpan.Zero, stored.StartedAt.Offset);

			var transcript = await db.Transcripts.AsNoTracking().SingleAsync(t => t.UserId == userId && t.ConversationId == id);
			Assert.Equal([TranscriptItemKind.Turn, TranscriptItemKind.Quiet, TranscriptItemKind.Masked], transcript.Items.Select(i => i.Kind));

			Assert.Equal([id], await SearchAsync(db, userId, "firmware"));
			Assert.Equal([id], await SearchAsync(db, userId, "audiobook"));
			Assert.Equal([id], await SearchAsync(db, userId, "publishing paused"));
			Assert.Empty(await SearchAsync(db, userId, "cricket"));
		}
	}

	/// <summary>
	/// Search across both halves of the vector: the conversation's (title, tags, summary) and its transcript's.
	/// </summary>
	private static Task<List<string>> SearchAsync(ArchiveDbContext db, Guid userId, string terms) =>
		(
			from conversation in db.Conversations
			join transcript in db.Transcripts
				on new { conversation.UserId, ConversationId = conversation.Id } equals new { transcript.UserId, transcript.ConversationId }
				into transcripts
			from transcript in transcripts.DefaultIfEmpty()
			where conversation.UserId == userId &&
				(conversation.SearchVector.Matches(EF.Functions.WebSearchToTsQuery("english", terms)) ||
					(transcript != null && transcript.SearchVector.Matches(EF.Functions.WebSearchToTsQuery("english", terms))))
			select conversation.Id)
			.ToListAsync();
}
