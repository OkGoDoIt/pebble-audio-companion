using System.ComponentModel;
using System.Text;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.AI;
using ModelContextProtocol;
using ModelContextProtocol.Protocol;
using ModelContextProtocol.Server;
using PebbleAudio.Server.Data;

namespace PebbleAudio.Server.Mcp;

/// <summary>
/// The archive as MCP resources, for clients that attach them to a chat (Claude's composer menu, for one):
/// <c>conversation://{id}</c> and <c>day://{date}</c>, both Markdown, both inside the sharing scope and logged.
/// </summary>
[McpServerResourceType]
public sealed class ArchiveResources
{
	[McpServerResource(UriTemplate = "conversation://{id}", Name = "conversation", Title = "A conversation", MimeType = "text/markdown")]
	[Description("One conversation as Markdown: title, time, overview, and the transcript with its quiet and lost markers.")]
	public static async Task<TextResourceContents> Conversation(
		RequestContext<ReadResourceRequestParams> context,
		ArchiveReader archive,
		string id,
		CancellationToken cancellationToken)
	{
		var call = await archive.BeginAsync(context.User, cancellationToken);
		var conversationId = Uri.UnescapeDataString(id);
		var conversation = await archive.Conversations(call).SingleOrDefaultAsync(c => c.Id == conversationId, cancellationToken)
			?? throw new McpException($"There is no conversation “{conversationId}” in what the person shares.");
		var transcript = await archive.Transcripts(call).SingleOrDefaultAsync(t => t.ConversationId == conversationId, cancellationToken);
		var rendered = ArchiveText.Conversation(conversation, transcript, call.Settings.ToolMaxCharacters - 500, markdown: true);
		var text = new StringBuilder(rendered.Text);
		text.Append("\n\n").Append(archive.Links.Conversation(conversationId));
		if (rendered.Truncated)
		{
			text.Append("\n\nThe transcript continues: call get_conversation with include transcript and from_time to read on.");
		}

		await archive.LogAsync(call, "resource:conversation", [conversationId], cancellationToken);
		return new TextResourceContents { Uri = $"conversation://{id}", MimeType = "text/markdown", Text = text.ToString() };
	}

	[McpServerResource(UriTemplate = "day://{date}", Name = "day", Title = "A day", MimeType = "text/markdown")]
	[Description("One day as Markdown: the recap, how it was covered, and its conversations with links. The date is yyyy-MM-dd, today, or yesterday.")]
	public static async Task<TextResourceContents> Day(
		RequestContext<ReadResourceRequestParams> context,
		ArchiveReader archive,
		string date,
		CancellationToken cancellationToken)
	{
		var call = await archive.BeginAsync(context.User, cancellationToken);
		if (!Days.TryParse(Uri.UnescapeDataString(date), call.Today, out var day))
		{
			throw new McpException(DayTools.DayHelp);
		}

		var result = await DayTools.DayAsync(archive, call, day, cancellationToken);
		var text = new StringBuilder();
		text.Append("# ").Append(Speak.Day(day, call.Today));
		if (result.Recap?.Headline is { } headline)
		{
			text.Append(": ").Append(headline);
		}

		text.Append("\n\n").Append(result.Summary).Append('\n');
		if (result.Recap?.Text is { } recap)
		{
			text.Append('\n').Append(recap).Append('\n');
		}

		if (result.Coverage is { } coverage)
		{
			text.Append($"\nRecorded {Speak.Duration(coverage.RecordedMinutes)}, quiet {Speak.Duration(coverage.QuietMinutes)}, lost {Speak.Duration(coverage.LostMinutes)}.\n");
		}

		if (result.Conversations.Count > 0)
		{
			text.Append("\n## Conversations\n\n");
			foreach (var card in result.Conversations)
			{
				text.Append($"- {card.StartedAt:HH:mm} [{card.Title ?? "Untitled conversation"}]({card.Url}) ({Speak.Duration(card.Minutes)}");
				if (card.LostMinutes > 0)
				{
					text.Append($", {Speak.Duration(card.LostMinutes)} lost");
				}

				text.Append(')');
				if (card.Overview is { } overview)
				{
					text.Append(": ").Append(overview);
				}

				text.Append('\n');
			}
		}

		if (result.FollowUps.Count > 0)
		{
			// Reminders are the person's list; a follow-up to review is only something the app noticed.
			var reminders = result.FollowUps.Where(f => f.Stage == FollowUpStage.Reminder.ToWire()).ToList();
			var toReview = result.FollowUps.Where(f => f.Stage == FollowUpStage.Suggested.ToWire()).ToList();
			if (reminders.Count > 0)
			{
				text.Append("\n## Reminders\n\n");
				foreach (var followUp in reminders)
				{
					text.Append($"- [{followUp.Text}]({followUp.Url}) ({followUp.Status})\n");
				}
			}

			if (toReview.Count > 0)
			{
				text.Append("\n## Follow-ups to review\n\n");
				foreach (var followUp in toReview)
				{
					text.Append($"- [{followUp.Text}]({followUp.Url})\n");
				}
			}
		}

		if (result.Url is { } url)
		{
			text.Append('\n').Append(url).Append('\n');
		}

		await archive.LogAsync(call, "resource:day", [Days.Key(day), .. result.Conversations.Select(c => c.Id)], cancellationToken);
		return new TextResourceContents { Uri = $"day://{date}", MimeType = "text/markdown", Text = text.ToString() };
	}
}

/// <summary>Ready-made requests for clients that offer prompts (slash commands, the composer menu).</summary>
[McpServerPromptType]
public sealed class ArchivePrompts
{
	[McpServerPrompt(Name = "brief_me_on_a_day", Title = "Brief me on a day")]
	[Description("A five-line brief of one day from Pebble Audio, with links.")]
	public static ChatMessage BriefMeOnADay(
		[Description("The day: yyyy-MM-dd, today, or yesterday. Default: yesterday.")] string? date = null)
	{
		var day = string.IsNullOrWhiteSpace(date) ? "yesterday" : date.Trim();
		return new ChatMessage(
			ChatRole.User,
			$"Using Pebble Audio, brief me on {day} in five lines: what I did, who I talked with, decisions, open reminders, " +
			"and anything I said I would do next. Start with get_day; open a conversation with get_conversation only when " +
			"the recap leaves something unclear. Put the link after each item, and say if any of the day's audio was lost.");
	}

	[McpServerPrompt(Name = "what_did_i_promise_this_week", Title = "What did I promise this week")]
	[Description("The reminders from the last seven days, with where each was said.")]
	public static ChatMessage WhatDidIPromiseThisWeek() =>
		new(
			ChatRole.User,
			"Using Pebble Audio, list what I promised or said I would do in the last seven days. Start with my reminders: " +
			"list_follow_ups with status open, then with status done, both from six days ago. Then search the same days " +
			"for promises in my own words that are not reminders (\"I'll\", \"I will\", \"let me\"). Follow-ups waiting " +
			"for my review are things the app noticed, not promises; leave them out. For each: what, to whom, when it is " +
			"due, whether it is done, and the link to the moment. Say which days you read.");
}
