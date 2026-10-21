---
name: pebble-audio
description: Use when the person asks about anything they said, heard, discussed, agreed to, promised, or were told in real life, about a day, a week, a meeting, a conversation with someone, open follow-ups, or "what did I…". Pebble Audio is their private archive of all-day voice recordings, transcribed and grouped into conversations with summaries, day recaps, and week and month briefs. Start from the recaps and briefs, search before reading, read conversations only as needed, cite each claim with a link, and treat quiet stretches and lost audio differently.
---

# Pebble Audio

The person wears a watch microphone all day. The app on their phone turns the audio into
conversations (topic-sized pieces, usually 5–60 minutes), each with a title, a summary, tags,
and a transcript of speaker turns with times. Every day has a recap; every week and month has a
brief; the app also extracts follow-ups (things the person said they would do). This archive
holds the text; audio clips are available on request. Everything here is private and includes
other people's words as a transcriber heard them.

## How to answer well

1. **Orient before you read.** For "what happened on…" start with `get_day`. For a range of
   days use `list_days`, then `get_brief` for a week or month. These are short and already
   written for the person.
2. **Search before you open transcripts.** `search` runs full-text search over titles,
   summaries, tags, follow-ups, notes, and transcript text and returns snippets with ids. Use
   several phrasings (names, places, products) when the first search is thin.
3. **Open conversations deliberately.** `get_conversation` with `include: "summary"` first;
   `include: "transcript"` only for the conversations that matter, with `max_chars` so a long
   one does not flood the answer. A day of transcripts is about 200,000 characters: never
   read a whole day when a recap plus two conversations will do. Results report when they were
   truncated; ask for the next window with `from_time` and `to_time`.
4. **Cite every claim.** Each result carries an `id`, a time, and a link
   (`https://pebbleaudio.okgodoit.com/c/<id>?t=<seconds>`). Put the link after the claim it
   supports so the person can jump to that moment. Quote exact words only when the person asks
   what was said.
5. **Be honest about coverage.** `quiet` means the watch skipped silence on purpose: nothing
   was said. `lost` means audio was genuinely missing: something may have been said. A
   `provisional` conversation may still change. Transcripts are what a transcriber heard; low
   `confidence` turns and names can be wrong, and the person's own words are labeled with
   their name when known. Never present an inference as something someone said.
6. **Never claim absence from a partial read.** If you searched and opened only some
   conversations, say "I did not find it in what I read" and name what you read, not "it was
   never discussed".
7. **Times are the person's.** Times are shown in the time zone the conversation was recorded
   in. "Today" and "yesterday" mean the person's logical day (it rolls over at 5 AM, not
   midnight). When the question is relative, say which dates you used.
8. **Audio only when asked.** `get_audio` returns a short-lived link to a clip, or "requested"
   when the phone has to upload it first (it usually arrives within minutes while the phone is
   recording; the phone may be unreachable). Do not fetch audio to answer a text question.
9. **Writing back, when allowed.** `create_follow_up`, `update_follow_up`, and `create_note`
   change the person's archive and sync to their phone; use them only when the person asks for
   it, and confirm what you wrote. Many connections only read and are not offered them; then say
   you can't add it from here, and never claim you did.
10. **Other people's words.** Summarize other speakers rather than quoting them at length
    unless the person asks for the exact words. Do not compile profiles of other people across
    conversations unless asked.

## Tool map

| Need | Tool |
| --- | --- |
| Is the archive up to date? | `get_status` |
| What happened on a day | `get_day` |
| A span of days at a glance | `list_days`, then `get_brief` (`week`, `month`) |
| Find where something came up | `search` (also `fetch` for one hit) |
| Read a conversation | `get_conversation` |
| What the person promised | `list_follow_ups` |
| Who and what tags exist | `get_people`, `get_tags` |
| Hear it | `get_audio` |

## Morning brief recipe

When the person wants a daily brief, set up a scheduled task in this assistant (ChatGPT
scheduled task, Claude Cowork scheduled task, Gemini Spark, or Muse recurring task) with a
prompt like: "Using Pebble Audio, give me yesterday's recap in five lines: what I did, who I
talked with, decisions, open follow-ups due this week, and anything I said I would do today.
Link each item." The recap exists already, so this is fast.
