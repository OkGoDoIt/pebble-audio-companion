using Microsoft.AspNetCore.Identity;
using Microsoft.AspNetCore.Identity.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore;
using PebbleAudio.Server.Auth;

namespace PebbleAudio.Server.Data;

/// <summary>
/// The archive database, which is also the Identity store. Every archive table is scoped by <c>UserId</c>.
/// </summary>
public sealed partial class ArchiveDbContext(DbContextOptions<ArchiveDbContext> options)
	: IdentityDbContext<ApplicationUser, IdentityRole<Guid>, Guid>(options)
{
	public DbSet<Conversation> Conversations => Set<Conversation>();

	public DbSet<Transcript> Transcripts => Set<Transcript>();

	public DbSet<Recap> Recaps => Set<Recap>();

	public DbSet<Brief> Briefs => Set<Brief>();

	public DbSet<FollowUp> FollowUps => Set<FollowUp>();

	public DbSet<Note> Notes => Set<Note>();

	public DbSet<Person> People => Set<Person>();

	public DbSet<CoverageDay> CoverageDays => Set<CoverageDay>();

	public DbSet<SyncItem> SyncItems => Set<SyncItem>();

	public DbSet<SyncPreferences> SyncPreferences => Set<SyncPreferences>();

	public DbSet<Device> Devices => Set<Device>();

	public DbSet<LinkCode> LinkCodes => Set<LinkCode>();

	public DbSet<PhoneRequest> Requests => Set<PhoneRequest>();

	public DbSet<Clip> Clips => Set<Clip>();

	public DbSet<Job> Jobs => Set<Job>();

	public DbSet<ApiToken> ApiTokens => Set<ApiToken>();

	public DbSet<AiRead> AiReads => Set<AiRead>();

	public DbSet<ArchiveSetting> Settings => Set<ArchiveSetting>();

	protected override void ConfigureConventions(ModelConfigurationBuilder configurationBuilder)
	{
		// Enums are stored as their member names, readable in psql and safe to reorder.
		configurationBuilder.Properties<Enum>().HaveConversion<string>();
	}

	protected override void OnModelCreating(ModelBuilder builder)
	{
		base.OnModelCreating(builder);

		builder.Entity<Conversation>(entity =>
		{
			entity.HasKey(c => new { c.UserId, c.Id });
			entity.HasIndex(c => new { c.UserId, c.DayKey });
			entity.HasIndex(c => new { c.UserId, c.StartedAt });
			entity.ComplexCollection(c => c.Pieces, pieces => pieces.ToJson());
			entity.ComplexCollection(c => c.People, people => people.ToJson());
			entity.ComplexCollection(c => c.Gaps, gaps => gaps.ToJson());
			entity.Property(c => c.SearchVector)
				.HasColumnType("tsvector")
				.HasComputedColumnSql(SearchSql.ConversationVector, stored: true);
			entity.HasIndex(c => c.SearchVector).HasMethod("GIN");
		});

		builder.Entity<Transcript>(entity =>
		{
			entity.HasKey(t => new { t.UserId, t.ConversationId });
			entity.ComplexCollection(t => t.Items, items => items.ToJson());
			entity.HasGeneratedTsVectorColumn(t => t.SearchVector, SearchSql.TextSearchConfig, t => new { t.Text })
				.HasIndex(t => t.SearchVector)
				.HasMethod("GIN");
		});

		builder.Entity<Recap>(entity => entity.HasKey(r => new { r.UserId, r.DayKey }));

		builder.Entity<Brief>(entity =>
		{
			entity.HasKey(b => new { b.UserId, b.PeriodKey });
			entity.HasIndex(b => new { b.UserId, b.Kind, b.StartDay });
		});

		builder.Entity<FollowUp>(entity =>
		{
			entity.HasKey(f => new { f.UserId, f.Id });
			entity.HasIndex(f => new { f.UserId, f.SourceConversationId });
		});

		builder.Entity<Note>(entity =>
		{
			entity.HasKey(n => new { n.UserId, n.Id });
			entity.HasIndex(n => new { n.UserId, n.ConversationId });
			entity.ComplexCollection(n => n.Citations, citations => citations.ToJson());
		});

		builder.Entity<Person>(entity => entity.HasKey(p => new { p.UserId, p.Id }));

		builder.Entity<CoverageDay>(entity =>
		{
			entity.HasKey(c => new { c.UserId, c.DayKey });
			entity.ComplexCollection(c => c.Spans, spans => spans.ToJson());
		});

		builder.Entity<SyncItem>(entity =>
		{
			entity.HasKey(s => new { s.UserId, s.Kind, s.EntityId });
			entity.HasIndex(s => new { s.UserId, s.AppliedAt });
		});

		builder.Entity<SyncPreferences>(entity => entity.HasKey(p => p.UserId));

		builder.Entity<Device>(entity =>
		{
			entity.HasIndex(d => d.TokenHash).IsUnique();
			entity.HasIndex(d => d.UserId);
		});

		builder.Entity<LinkCode>(entity =>
		{
			entity.HasIndex(l => l.CodeHash).IsUnique();
			entity.HasIndex(l => l.UserId);
		});

		builder.Entity<PhoneRequest>(entity =>
		{
			entity.ToTable("Requests");
			entity.HasIndex(r => new { r.UserId, r.State, r.CreatedAt });
		});

		builder.Entity<Clip>(entity =>
		{
			entity.HasIndex(c => c.RequestId).IsUnique();
			entity.HasIndex(c => new { c.UserId, c.ConversationId });
			entity.ComplexCollection(c => c.Gaps, gaps => gaps.ToJson());
			entity.HasOne<PhoneRequest>().WithMany().HasForeignKey(c => c.RequestId).OnDelete(DeleteBehavior.Cascade);
		});

		builder.Entity<Job>(entity =>
		{
			entity.Property(j => j.Id).UseIdentityAlwaysColumn();
			// The claim query only ever looks at pending jobs that are due.
			entity.HasIndex(j => j.RunAfter).HasFilter("\"State\" = 'Pending'");
			entity.HasIndex(j => new { j.State, j.CompletedAt });
			entity.HasOne<ApplicationUser>().WithMany().HasForeignKey(j => j.UserId).OnDelete(DeleteBehavior.Cascade);
		});

		builder.Entity<ApiToken>(entity =>
		{
			entity.HasIndex(t => t.TokenHash).IsUnique();
			entity.HasIndex(t => t.UserId);
		});

		builder.Entity<AiRead>(entity =>
		{
			entity.Property(a => a.Id).UseIdentityAlwaysColumn();
			entity.HasIndex(a => new { a.UserId, a.At });
		});

		builder.Entity<ArchiveSetting>(entity =>
		{
			entity.ToTable("Settings");
			entity.HasKey(s => s.Key);
		});

		// Every user-scoped row goes with its user. The job queue's UserId is optional and configured above.
		ConfigureOwner<Conversation>(builder);
		ConfigureOwner<Transcript>(builder);
		ConfigureOwner<Recap>(builder);
		ConfigureOwner<Brief>(builder);
		ConfigureOwner<FollowUp>(builder);
		ConfigureOwner<Note>(builder);
		ConfigureOwner<Person>(builder);
		ConfigureOwner<CoverageDay>(builder);
		ConfigureOwner<SyncItem>(builder);
		ConfigureOwner<SyncPreferences>(builder);
		ConfigureOwner<Device>(builder);
		ConfigureOwner<LinkCode>(builder);
		ConfigureOwner<PhoneRequest>(builder);
		ConfigureOwner<Clip>(builder);
		ConfigureOwner<ApiToken>(builder);
		ConfigureOwner<AiRead>(builder);

		OAuthModel.Configure(builder);
		EventsModel.Configure(builder);
	}

	private static void ConfigureOwner<TEntity>(ModelBuilder builder)
		where TEntity : class
	{
		builder.Entity<TEntity>()
			.HasOne<ApplicationUser>()
			.WithMany()
			.HasForeignKey("UserId")
			.OnDelete(DeleteBehavior.Cascade);
	}
}
