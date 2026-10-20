using System.Globalization;
using Microsoft.EntityFrameworkCore;
using PebbleAudio.Server.Data;

namespace PebbleAudio.Server.Settings;

/// <summary>
/// Reads and saves <see cref="ArchiveSettings"/>. Reads go to the database every time: it is a handful of
/// rows, and a change takes effect on the next request without a cache to invalidate.
/// </summary>
public sealed class SettingsService(ArchiveDbContext db, TimeProvider time)
{
	public async Task<ArchiveSettings> GetAsync(CancellationToken cancellationToken)
	{
		var stored = await db.Settings.AsNoTracking().ToDictionaryAsync(s => s.Key, s => s.Value, cancellationToken);
		var settings = ArchiveSettings.Defaults;
		foreach (var definition in SettingDefinition.All)
		{
			if (stored.TryGetValue(definition.Key, out var raw) &&
				int.TryParse(raw, NumberStyles.Integer, CultureInfo.InvariantCulture, out var value) &&
				value >= definition.Min &&
				value <= definition.Max)
			{
				settings = definition.With(settings, value);
			}
		}

		return settings;
	}

	/// <summary>
	/// Saves new values. A value equal to its default removes the stored row, so a later change of default
	/// reaches it. Keys that are not settings and values out of range are refused.
	/// </summary>
	public async Task SaveAsync(IReadOnlyDictionary<string, int> values, CancellationToken cancellationToken)
	{
		var definitions = SettingDefinition.All.ToDictionary(d => d.Key, StringComparer.Ordinal);
		foreach (var (key, value) in values)
		{
			if (!definitions.TryGetValue(key, out var definition))
			{
				throw new ArgumentException($"'{key}' is not a setting.", nameof(values));
			}

			if (value < definition.Min || value > definition.Max)
			{
				throw new ArgumentOutOfRangeException(nameof(values), value, $"{definition.Label} must be between {definition.Min} and {definition.Max}.");
			}
		}

		var rows = await db.Settings.ToDictionaryAsync(s => s.Key, StringComparer.Ordinal, cancellationToken);
		var now = time.GetUtcNow();
		foreach (var (key, value) in values)
		{
			var definition = definitions[key];
			rows.TryGetValue(key, out var row);
			if (value == definition.Default)
			{
				if (row is not null)
				{
					db.Settings.Remove(row);
				}

				continue;
			}

			var text = value.ToString(CultureInfo.InvariantCulture);
			if (row is null)
			{
				db.Settings.Add(new ArchiveSetting { Key = key, Value = text, UpdatedAt = now });
			}
			else if (row.Value != text)
			{
				row.Value = text;
				row.UpdatedAt = now;
			}
		}

		await db.SaveChangesAsync(cancellationToken);
	}
}
