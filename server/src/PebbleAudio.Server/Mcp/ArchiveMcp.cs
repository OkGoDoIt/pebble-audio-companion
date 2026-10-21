using Microsoft.Extensions.DependencyInjection;

namespace PebbleAudio.Server.Mcp;

/// <summary>
/// Registers the archive's MCP surface (docs/tool-results.md): the read tools, <c>search</c> and <c>fetch</c>,
/// <c>get_audio</c>, the write tools, the <c>conversation://</c> and <c>day://</c> resources, and the prompts.
/// </summary>
public static class ArchiveMcp
{
	public static IMcpServerBuilder WithArchive(this IMcpServerBuilder builder)
	{
		builder.Services.AddSingleton<ViewerLinks>();
		builder.Services.AddScoped<ArchiveReader>();
		builder.Services.AddScoped<ArchiveSearch>();
		builder.Services.AddOptions<ModelContextProtocol.Server.McpServerOptions>().Configure(CacheHints.Add).PostConfigure(OutputSchemas.Relax);
		return builder
			.WithTools<StatusTools>()
			.WithTools<DayTools>()
			.WithTools<ConversationTools>()
			.WithTools<SearchTools>()
			.WithTools<VocabularyTools>()
			.WithTools<AudioTools>()
			.WithTools<WriteTools>()
			.WithResources<ArchiveResources>()
			.WithPrompts<ArchivePrompts>();
	}
}
