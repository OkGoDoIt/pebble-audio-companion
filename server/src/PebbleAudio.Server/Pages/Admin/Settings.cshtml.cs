using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;
using PebbleAudio.Server.Settings;

namespace PebbleAudio.Server.Pages.Admin;

public sealed class SettingsModel(SettingsService settings) : PageModel
{
	public ArchiveSettings Current { get; private set; } = ArchiveSettings.Defaults;

	[BindProperty]
	public Dictionary<string, int> Values { get; set; } = [];

	[BindProperty(SupportsGet = true)]
	public bool Saved { get; set; }

	public async Task OnGetAsync(CancellationToken cancellationToken)
	{
		Current = await settings.GetAsync(cancellationToken);
		Values = [];
	}

	public async Task<IActionResult> OnPostAsync(CancellationToken cancellationToken)
	{
		foreach (var definition in SettingDefinition.All)
		{
			var field = $"Values[{definition.Key}]";
			if (!Values.TryGetValue(definition.Key, out var value) || value < definition.Min || value > definition.Max)
			{
				// Replaces the model binder's own wording for a value that is not a number.
				ModelState.Remove(field);
				ModelState.AddModelError(field, $"Use a whole number from {definition.Min:N0} to {definition.Max:N0}.");
			}
		}

		if (!ModelState.IsValid)
		{
			Current = await settings.GetAsync(cancellationToken);
			return Page();
		}

		var known = SettingDefinition.All.Select(d => d.Key).ToHashSet(StringComparer.Ordinal);
		await settings.SaveAsync(Values.Where(v => known.Contains(v.Key)).ToDictionary(), cancellationToken);
		return RedirectToPage(new { saved = true });
	}

	public async Task<IActionResult> OnPostResetAsync(CancellationToken cancellationToken)
	{
		await settings.SaveAsync(SettingDefinition.All.ToDictionary(d => d.Key, d => d.Default), cancellationToken);
		return RedirectToPage(new { saved = true });
	}
}
