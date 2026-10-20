using Microsoft.AspNetCore.Identity;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Design;

namespace PebbleAudio.Server.Data;

/// <summary>
/// Lets the EF tools (migrations, bundles) build the same model as the app, including Identity's schema
/// version 3 passkey table, without starting the app. The bundle's <c>--connection</c> replaces the
/// connection string at run time.
/// </summary>
public sealed class ArchiveDbContextFactory : IDesignTimeDbContextFactory<ArchiveDbContext>
{
	public ArchiveDbContext CreateDbContext(string[] args)
	{
		var connectionString = Environment.GetEnvironmentVariable("ConnectionStrings__DefaultConnection")
			?? "Host=localhost;Database=pebbleaudio";

		var services = new ServiceCollection();
		services.AddOptions();
		services.Configure<IdentityOptions>(options => options.Stores.SchemaVersion = IdentitySchemaVersions.Version3);

		var optionsBuilder = new DbContextOptionsBuilder<ArchiveDbContext>();
		optionsBuilder.UseNpgsql(connectionString, npgsql =>
			npgsql.UseQuerySplittingBehavior(QuerySplittingBehavior.SplitQuery));
		optionsBuilder.UseApplicationServiceProvider(services.BuildServiceProvider());

		return new ArchiveDbContext(optionsBuilder.Options);
	}
}
