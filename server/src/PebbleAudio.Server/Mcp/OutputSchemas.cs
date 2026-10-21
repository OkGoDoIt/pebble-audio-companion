using System.Text.Json;
using System.Text.Json.Nodes;
using ModelContextProtocol.Server;

namespace PebbleAudio.Server.Mcp;

/// <summary>
/// Makes each tool's output schema say what its structured content does. The SDK generates the schema from the
/// result record and lists every property as required, nullable ones too, while results leave a null field out
/// (docs/tool-results.md). A client that validates (OpenAI: structured content must match the declared schema) would
/// then refuse most results. A property whose type allows null is taken out of <c>required</c>, at every depth.
/// <para>
/// Every schema, input and output, is also written out in full. The SDK's exporter points a type it has already
/// written at its first spelling (<c>{"$ref": "#/properties/lost"}</c>), and Gemini cannot read a schema with
/// <c>$ref</c> or <c>$defs</c>, so each reference is replaced by a copy of what it points at.
/// </para>
/// </summary>
public static class OutputSchemas
{
	/// <summary>How deep a reference may lead back into itself before it is left as "anything".</summary>
	private const int MaxInlineDepth = 16;

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
				root = Inline(root);
				Relax(root);
				tool.ProtocolTool.OutputSchema = JsonSerializer.SerializeToElement(root);
			}

			if (JsonNode.Parse(tool.ProtocolTool.InputSchema.GetRawText()) is JsonObject input && HasReference(input))
			{
				tool.ProtocolTool.InputSchema = JsonSerializer.SerializeToElement(Inline(input));
			}
		}
	}

	/// <summary>The schema with every local <c>$ref</c> replaced by what it points at, and no <c>$defs</c> left.</summary>
	internal static JsonObject Inline(JsonObject root)
	{
		var copy = (JsonObject)Resolve(root, root, 0)!;
		copy.Remove("$defs");
		copy.Remove("definitions");
		return copy;
	}

	private static JsonNode? Resolve(JsonNode? node, JsonObject root, int depth)
	{
		switch (node)
		{
			case JsonObject schema when schema["$ref"] is JsonValue reference && reference.TryGetValue<string>(out var pointer):
			{
				if (depth >= MaxInlineDepth || Find(root, pointer) is not JsonObject target)
				{
					return new JsonObject();
				}

				// What it points at, then anything else said beside the reference.
				var inlined = (JsonObject)Resolve(target, root, depth + 1)!;
				foreach (var (key, value) in schema)
				{
					if (key != "$ref")
					{
						inlined[key] = Resolve(value, root, depth);
					}
				}

				return inlined;
			}

			case JsonObject schema:
			{
				var copy = new JsonObject();
				foreach (var (key, value) in schema)
				{
					copy[key] = Resolve(value, root, depth);
				}

				return copy;
			}

			case JsonArray array:
				return new JsonArray([.. array.Select(item => Resolve(item, root, depth))]);

			default:
				return node?.DeepClone();
		}
	}

	/// <summary>A JSON pointer within this schema ("#", "#/properties/lost", "#/$defs/Span").</summary>
	private static JsonNode? Find(JsonObject root, string pointer)
	{
		if (!pointer.StartsWith('#'))
		{
			return null;
		}

		JsonNode? node = root;
		foreach (var raw in pointer[1..].Split('/', StringSplitOptions.RemoveEmptyEntries))
		{
			var part = Uri.UnescapeDataString(raw).Replace("~1", "/", StringComparison.Ordinal).Replace("~0", "~", StringComparison.Ordinal);
			node = node switch
			{
				JsonObject o => o[part],
				JsonArray a when int.TryParse(part, out var i) && i >= 0 && i < a.Count => a[i],
				_ => null,
			};
		}

		return node;
	}

	private static bool HasReference(JsonNode? node) => node switch
	{
		JsonObject o => o.ContainsKey("$ref") || o.ContainsKey("$defs") || o.ContainsKey("definitions") || o.Any(p => HasReference(p.Value)),
		JsonArray a => a.Any(HasReference),
		_ => false,
	};

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
