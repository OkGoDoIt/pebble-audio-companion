using Microsoft.AspNetCore.Identity;
using Microsoft.Extensions.DependencyInjection;
using PebbleAudio.Server.Auth;
using PebbleAudio.Server.Data;

namespace PebbleAudio.Server.Tests;

internal static class TestData
{
	/// <summary>
	/// Creates a user with no passkey, the way rows get an owner in tests.
	/// </summary>
	public static async Task<Guid> CreateUserAsync(this ArchiveServerFactory factory)
	{
		await using var scope = factory.Services.CreateAsyncScope();
		var users = scope.ServiceProvider.GetRequiredService<UserManager<ApplicationUser>>();
		var user = new ApplicationUser
		{
			Id = Guid.CreateVersion7(),
			UserName = $"test-{Guid.NewGuid():N}",
			CreatedAt = DateTimeOffset.UtcNow,
		};
		var result = await users.CreateAsync(user);
		Assert.True(result.Succeeded, string.Join("; ", result.Errors.Select(e => e.Description)));
		return user.Id;
	}

	public static Conversation Conversation(Guid userId, string id, string title, params string[] tags)
	{
		var started = new DateTimeOffset(2026, 10, 14, 13, 5, 9, 754, TimeSpan.Zero);
		return new Conversation
		{
			UserId = userId,
			Id = id,
			Version = 1_791_999_175_292,
			ChangedAt = started.AddMinutes(30),
			ReceivedAt = DateTimeOffset.UtcNow,
			StartedAt = started,
			EndedAt = started.AddMinutes(23),
			TimeZone = "Asia/Jakarta",
			DayKey = new DateOnly(2026, 10, 14),
			State = ConversationState.Closed,
			StartReason = "topicChange",
			Title = title,
			Summary = "Alex and a friend talk through why the watch kept showing a paused audiobook as playing.",
			Tags = [.. tags],
			IsFinal = true,
			ContentKind = ContentKind.Conversation,
			HasMissingAudio = true,
			RecordedMs = 1_123_000,
			Pieces =
			[
				new ConversationPiece
				{
					Ordinal = 0,
					SegmentId = "seg-1791997844787-ed737f28-63",
					StartMediaMs = 83_010,
					StartedAt = started,
					EndedAt = started.AddMinutes(23),
				},
			],
			People = [new ConversationSpeaker { Label = "1", PersonId = "person-alex", Name = "Alex" }],
			Gaps =
			[
				new ConversationGap { StartedAt = started.AddMinutes(4), EndedAt = started.AddMinutes(5), Kind = GapKind.Lost, Origin = "watch" },
				new ConversationGap { StartedAt = started.AddMinutes(9), EndedAt = started.AddMinutes(11), Kind = GapKind.Quiet },
			],
		};
	}
}
