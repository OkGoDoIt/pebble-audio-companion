using System.Text.Json;
using System.Text.Json.Nodes;
using ModelContextProtocol.Server;

namespace PebbleAudio.Server.Mcp;

/// <summary>
/// Makes each tool's output schema say what its structured content does. The SDK generates the schema from the
/// result record and lists every property as required, nullable ones too, while results leave a null field out
/// (docs/tool-results.md). A client that validates (OpenAI: structured content must match the declared schema) would
/// then refuse most results. A property whose type allows null is taken out of <c>required</c>, at every depth.
/// </summary>
public static class OutputSchemas
{
	/// <summary>Runs once, after the SDK has collected the tools.</summary>
	public static void Relax(McpServerOptions options)
	{
		if (options.ToolCollection is not { } tools)
		{
			return;
		}

		foreach (var tool in tools)
		{
			if (tool.ProtocolTool.OutputSchema is { } schema && JsonNode.Parse(schema.GetRawText()) is JsonObject root)
			{
				Relax(root);
				tool.ProtocolTool.OutputSchema = JsonSerializer.SerializeToElement(root);
			}
		}
	}

	internal static void Relax(JsonNode? node)
	{
		switch (node)
		{
			case JsonObject schema:
				if (schema["properties"] is JsonObject properties && schema["required"] is JsonArray required)
				{
					var kept = required
						.Select(r => r?.GetValue<string>())
						.Where(name => name is not null && !AllowsNull(properties[name]))
						.Select(name => (JsonNode?)name)
						.ToArray();
					schema["required"] = new JsonArray(kept);
				}

				foreach (var (_, child) in schema.ToList())
				{
					Relax(child);
				}

				break;
			case JsonArray array:
				foreach (var item in array)
				{
					Relax(item);
				}

				break;
		}
	}

	private static bool AllowsNull(JsonNode? property) => property switch
	{
		JsonObject p when p["type"] is JsonArray types => types.Any(t => t?.GetValue<string>() == "null"),
		JsonObject p when p["type"] is JsonValue type => type.GetValue<string>() == "null",
		JsonObject p when p["anyOf"] is JsonArray options => options.Any(o => o is JsonObject x && AllowsNull(x)),
		_ => false,
	};
}
