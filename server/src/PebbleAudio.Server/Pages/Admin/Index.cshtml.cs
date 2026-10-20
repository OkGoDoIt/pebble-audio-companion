using Microsoft.AspNetCore.Mvc.RazorPages;
using PebbleAudio.Server.Auth;
using PebbleAudio.Server.Data;

namespace PebbleAudio.Server.Pages.Admin;

public sealed class IndexModel(ArchiveStatusService statusService, TimeProvider time) : PageModel
{
	public ArchiveStatus Status { get; private set; } = null!;

	public SyncFreshness Freshness { get; private set; }

	public IReadOnlyList<(string Label, int Count)> Counts { get; private set; } = [];

	public async Task OnGetAsync(CancellationToken cancellationToken)
	{
		var userId = User.UserId() ?? throw new InvalidOperationException("The admin page requires a signed-in user.");
		Status = await statusService.GetAsync(userId, cancellationToken);
		Freshness = Status.LastSyncAt switch
		{
			null => SyncFreshness.Never,
			{ } at when time.GetUtcNow() - at < TimeSpan.FromHours(1) => SyncFreshness.Recent,
			_ => SyncFreshness.Stale,
		};

		var counts = Status.Counts;
		Counts =
		[
			("Conversations", counts.Conversations),
			("Transcripts", counts.Transcripts),
			("Day recaps", counts.Recaps),
			("Briefs", counts.Briefs),
			("Follow-ups", counts.FollowUps),
			("Notes", counts.Notes),
			("People", counts.People),
			("Coverage days", counts.CoverageDays),
		];
	}

	public enum SyncFreshness
	{
		Never,
		Recent,
		Stale,
	}
}
