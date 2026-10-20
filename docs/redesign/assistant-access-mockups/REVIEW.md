# Assistant access: review of three directions

Reviewer's brief: judge settings-native, assistant-first, and privacy-ladder against the owner's
rules. The rules are: optional and off by default, each screen answers its user's questions in
order and once, honest about what leaves the phone, a privacy state as plain as the existing ones,
built from the app's design system, written in the product's voice with no mechanism words,
accessible, and as few steps as possible. I read every HTML file and looked at every PNG and
contact sheet. I compared copy against `ios/App/DesignSystem/Copy+PrivacyStance.swift` and
`Copy+ArchiveServer.swift`, and colors against `Tokens.swift`.

## Scores

| Direction | Score | One line |
|---|---|---|
| settings-native | **7.5** | The calmest, the most faithful to the app, and the plainest Privacy screen. Its setup is a little long, and its connect and linked screens are generic. |
| assistant-first | **7.0** | The best linking and connect mechanics: a step bar, Copy Address and Open, the Mac path, and an honest Unlink. Brand logos, an Ask-tab promo, and a diagram on Privacy make it less calm. |
| privacy-ladder | **6.0** | A strong idea (the order of permissions shows what each one adds), but the diagram repeats on almost every screen, and two honesty slips land on the setup's most important screens. |

No forbidden mechanism words (MCP, OAuth, token, sync batch, API) appear in user copy in any
direction. The `token` matches in the HTML are only the `tokens.css` link. Oxford commas are
consistent everywhere.

---

## settings-native (7.5)

**Strengths**
- **Most clearly optional.** Settings shows one row, `AI Assistants · Off`, beside Privacy (`01-settings.html`). The off page is a state plus one line: "ChatGPT, Claude, and other assistants can't read your conversations." (`01b-assistants-off.html`). Nothing is promoted anywhere else.
- **The Privacy screen keeps today's structure exactly.** It has the stance card, then `Siri & Spotlight can see`, then a parallel `AI assistants can read` row whose value goes Off, None yet, ChatGPT, Claude (`07a`/`07b`/`07c`). The readers' names are set in bold in the value position, so they pass the squint test without a new motif. This is the plainest new state of the three, and the only one that keeps all five existing commitments.
- **The headline names the readers.** "ChatGPT and Claude can read your text" (`07c-privacy-assistants.html`), and "Only text goes to your server" reuses the shipping string.
- **History scope is its own answer.** It offers "All conversations, 214 conversations, back to August 12" or "From today on, Earlier conversations stay on this phone" (`04-choices.html`). That is a real consent question, asked with numbers the phone already knows.
- **Design-system fidelity.** It uses OptionCards, grouped lists, the stance card, and switches, all on `Tokens.swift` values. Footnotes moved from `meta` to `tertiary` for AA at 13 pt, which is a real fix the app should adopt.
- **Linked screen order.** It goes status, Sync, Who can read (with each assistant's last read), Assistants can, then Unlink (`06-linked.html`). The assistant detail lists what that assistant read, followed by `Disconnect ChatGPT` and its consequence (`06b-assistant.html`).
- **Expired code** keeps the camera live and uses a heading plus one line: "This code has expired / Codes last ten minutes. Open Link a phone on your server for a new one." (`03b-link-expired.html`).

**Weaknesses**
- **An extra hop.** The path is Settings, then the AI Assistants off page, then `Set Up AI Assistants`, then the intro sheet. The off page repeats what the Settings value already says. When the feature is off, the row should open the introduction directly, as assistant-first's does.
- **Assistants are visually identical.** ChatGPT and Claude share the same gray chat-bubble tile (`05-connect.html`, `06-linked.html`). At squint size, the "who can read" list is three gray squares.
- **The Mac path is never shown.** "Codex, Claude Code, or Cursor · On a Mac" stays collapsed (`05-connect.html`, `05b-connect-chatgpt.html`), so the brief's third connect path goes undesigned.
- **"Read · All conversations"** under "Assistants can" (`06-linked.html`) mislabels the history scope. The scope decides what syncs to the server, not what assistants read. Call it "Includes · All conversations" or put it under the Sync row.
- **The Unlink footer leaves out the important fact.** "Your server keeps what it already has" (`06-linked.html`) does not say that connected assistants can still read it there.
- **The back button style predates iOS 26.** It is the text-and-chevron "‹ Settings". The app runs on iOS 26, which draws a glass circle. The other two directions got this right.
- **Steps.** There are four sheet screens plus the extra off page, five in all. The intro restates "Text goes to your server" facts that the choices screen and the linked footer then repeat.

## assistant-first (7.0)

**Strengths**
- **Setup reads as position.** A three-part Link · Choose · Connect bar shows checked steps (`03a`–`05c`). The person always knows how much is left, which the other two only say in words.
- **The best connect step** (`05a-connect-chatgpt.html`, `05b-connect-claude.html`, `05c-connect-mac.html`):
  - The server address is pinned once at the top with Copy.
  - Each assistant card has its own short numbered steps.
  - A single button says what it does: `Copy Address and Open ChatGPT`. `Open Claude` explains "Your server is already filled in."
  - A row turns into a green check with "Connected just now" only after the server confirms it, and shows a spinner until then.
  - It is the only direction that designs the Mac path ("open Connect an app … paste it into that app on your Mac", `05c`) and offers "Another assistant · Gemini, Meta Muse, and others".
- **Off is stated without hedging.** "Off until you set it up." sits above `Link Your Server` / `Not Now` (`02-intro.html`). The intro's three facts are short and correct: "Audio stays on this phone / Unless you let assistants ask for a short clip."
- **The Unlink footer is the most honest of the three.** "Your server keeps what it already has, and connected assistants can still read it there." (`06a-assistants-linked.html`).
- **The assistant detail logs writes too.** It shows "Send Priya the launch checklist · Added a follow-up" next to reads. Disconnect says "What it already read is up to OpenAI's own policies." (`06b-assistant-detail.html`).
- **The expired code** gets `Scan New Code` as the primary action, which is the right next step (`03b-link-expired.html`).
- **Assistants are recognizable at a glance.** Each has a distinct tile.

**Weaknesses**
- **Third-party brand marks.** The intro opens with an OpenAI-style knot, a Claude starburst, and a Gemini sparkle (`02-intro.html`). They also appear on Ask (`01a`), in Who can read (`06a`), and in the Privacy diagram (`07c`). That is an App Store trademark risk (5.2), it implies endorsement, and it makes the intro read like an ad. Use distinct neutral tiles built from tokens, with the name as text.
- **Promotion on the Ask tab.** "Ask from ChatGPT or Claude too", with logos, sits under Ask's history (`01a-ask-entry.html`). That is a cross-sell on a tab people use daily, not the "one calm line" off state. Keep the entry in Settings and Privacy only.
- **The intro's sample chat** (`02-intro.html`) is product marketing ("You'll send her the revised launch checklist…") and pushes the facts down. A one-line example question, as settings-native writes it, does the same job.
- **"Read your conversations · Always"** (`04-choices.html`) reads as permanent and unrevocable. It is a fixed row dressed as a setting. Drop the value, or say what it is: "Your conversations' text".
- **The pause control is named for something else.** The headline is "Sharing with your assistants", but the switch below it is "Share with your server" (`06a`). Off would pause the server, not the assistants, and no paused state is designed. Use one name: "Sync" (the shipping string) with "Sync is paused" as its state.
- **The Privacy screen adds a phone → server → assistants path diagram** inside the stance card (`07b`, `07c`). That is a new motif, it is heavier than today's card, and it breaks at large Dynamic Type (three fixed columns).
- **"Include past conversations" is on by default** (`04-choices.html`) as a green switch. Defensible, but it should be a deliberate owner decision, not a silent default.
- **The Privacy commitments drop the fifth line** (the Spotlight one) (`07a`).
- **The Settings row is just "Assistants"** (`01b-settings-entry.html`), which is ambiguous next to Ask's on-device assistant.

## privacy-ladder (6.0)

**Strengths**
- **The concept is honest by construction.** Four permissions in order: text to server, assistants read, clips, follow-ups and notes. A step can't be on before the one above it, and each off step is a gray dashed circle (`02-intro.html`, `04-choices.html`). It passes the squint test better than anything else.
- **The best honesty line about assistants.** "What it reads becomes part of your chats with it." (`06b-assistant-detail.html`, `07c-privacy-assistants.html`). This is concrete where the others say "up to them" or "up to their policies".
- **The assistant detail includes searches.** "Searched for 'cabinet quote' · Search" (`06b`) shows a person what an assistant looked for, not only what it opened.
- **Scanning** is a full in-app camera with "The Camera app can scan it too." and `Enter a Code Instead` (`03a-link-scan.html`).
- **The linked screen** nests the connected assistants under step 2, so "who can read" and "may they read" are one thing (`06a-linked.html`).
- **It raised the ChatGPT label conflict** in its index instead of hiding it.

**Weaknesses**
- **The diagram repeats on every screen.** It appears on the intro, link, code, choices, connect ×2, linked, assistant detail, and all three Privacy states. A screen should answer each question once, and the flow answers "where does my text go" nine times. It is also a new motif.
- **The scope choice comes after sync has started.** "Sending the text of 412 conversations to pebbleaudio.okgodoit.com." sits directly above the "Starting from · All conversations" choice (`04-choices.html`). Either sync has already started, which makes the choice moot, or the line is false. See Honesty.
- **The Privacy screen is the heaviest of the three** (`07b`, `07c`). It stacks the stance card, the diagram, a "Server & Assistants" four-step list, `Change What's Allowed`, and then Siri & Spotlight, pushed down to the fold. "Audio stays on this phone" sits in a numbered step slot, so a fact reads as a permission.
- **The commitments drop two of five** (backups, and Spotlight) (`07a`/`07b`/`07c`). "Included in the iPhone's usual backups" is a true and useful line to lose.
- **The diagram truncates the host.** It reads "Your server · okgodoit.com" (`07b`, `07c`), which names the wrong host.
- **Monogram tiles: "G" for ChatGPT, "C" for Claude** (`05a`, `06a`). "G" reads as Gemini.
- **The Settings row `Server & Assistants · •○○ Off`** (`01-settings-entry.html`) uses a three-dot indicator that looks like a page control. It is another new motif.
- **The choices screen has no Back or Cancel after linking.** It offers only `Skip for Now` (`04`).
- **The link-scan screen is dark-chromed with a white title** on an otherwise light flow (`03a`). Fine for a camera, but it is the only full-bleed camera, and it is a step longer than a camera inline with the code fields.

---

## Copy problems (precise)

1. **All three, Privacy commitments (`07b`/`07c`):** "Your recordings and transcripts are never sold or shared." This is false once ChatGPT and Claude read transcripts. Linked variant: "Your recordings and transcripts are never sold. They go only where this screen says they go."
2. **settings-native `04-choices.html`:** "They can read the text. The rest is up to you." is a slogan. A step head needs only the title, or one factual line.
3. **settings-native `06-linked.html`:** the row "Read · All conversations" is mislabeled. It is the history scope, not a read permission.
4. **settings-native:** capitalization of the feature name is inconsistent: "AI Assistants" (row and title), "AI assistants can read" (Privacy row), "Use with AI Assistants" (intro). Pick one noun and keep it.
5. **settings-native / privacy-ladder, ChatGPT step:** "Choose to add a custom server". ChatGPT's own button reads "Add custom MCP server". Write the step as "Tap **Add custom server**", so the visible words match apart from the forbidden one. This is an owner decision (the ladder flagged it).
6. **assistant-first `04-choices.html`:** the value "Always" next to "Read your conversations".
7. **assistant-first `06a`:** "Sharing with your assistants" (headline) versus "Share with your server" (switch). That is two names for one control. The shipping copy says "Sync" / "Sync is paused".
8. **assistant-first `02-intro.html`:** "Ask your assistants about your day" plus a sample chat is marketing register. The settings-native line, "Ask ChatGPT, Claude, or another assistant what you agreed to yesterday, and it answers from your conversations.", says it plainly.
9. **assistant-first `01a`:** "Ask from ChatGPT or Claude too" on the Ask tab is an upsell.
10. **assistant-first `01b`:** the row "Assistants" is ambiguous. Use "AI Assistants".
11. **privacy-ladder `02-intro.html`:** "Each step is yours to allow" is a slogan header. "Off until you turn it on." under step 4 repeats what the dashed circle and the footer already say.
12. **privacy-ladder `07c`:** "Audio stays on this phone" listed as permission step 3 mixes facts with permissions. Write it as "Assistants can't ask for clips".
13. **privacy-ladder `01-settings-entry.html`:** "Server & Assistants" leads with the machinery. The person's goal is the assistants.
14. **All:** "your server's admin page" (assistant-first, ladder) is acceptable because the server literally labels it, but "On your server, open Link a phone" (settings-native) is shorter and enough.

## Honesty problems (precise)

1. **The "never … shared" commitment** (all three, `07c`) contradicts the stance card directly above it. It must change in the linked configuration. The same bug exists in today's `Copy+PrivacyStance.swift` `linkedCommitments`.
2. **privacy-ladder `02-intro.html`:** "Nothing leaves this phone until you link a server of your own" is false for anyone using cloud transcription or cloud AI. Say "Nothing goes to a server of yours until you link one", or assistant-first's "Off until you set it up."
3. **settings-native `02-intro.html`:** "Nothing is shared until you link a server" is softer, but its own index says nothing syncs until the choices step is confirmed. Make the intro match: "Nothing syncs until you finish setting up."
4. **privacy-ladder `04-choices.html`:** "Sending the text of 412 conversations" appears before the person has chosen "Starting from". Nothing should send until the scope is chosen.
5. **Unlink copy** in settings-native `06-linked.html` and privacy-ladder `06a-linked.html` says only "Your server keeps what it already has." It must also say that connected assistants can still read it there, as assistant-first's `06a` does, or offer to disconnect them.
6. **"Audio stays on this phone" stated unconditionally** in settings-native `06-linked.html` (footer), privacy-ladder `06a`/`07c`, and the assistant-first `07c` diagram ("Your server · Text only"). The screens with clips off are true, but this copy has to be derived from the clips switch, as the shipping stance is derived from modes. With clips on: "Audio stays on this phone, except clips an assistant asks for."
7. **Privacy versus the linked state.** All three linked screens list ChatGPT, Claude, and Codex on Mac, and assistant-first has follow-ups on, but the Privacy states name only ChatGPT and Claude and say nothing about assistants writing. The brief asked for those states, but in the build the stance must name every reader and say "and can add follow-ups and notes" when that switch is on.
8. **privacy-ladder `07b`/`07c`:** "Your server · okgodoit.com" names a different host than the one the text goes to.
9. **settings-native `07c`:** "What ChatGPT and Claude keep from what they read is up to them" is true but vague. The ladder's "What they read becomes part of your chats with them" is the concrete, checkable version.
10. **Dropped commitments.** Privacy-ladder drops the backups and Spotlight commitments, and assistant-first drops Spotlight. These are true statements and should stay in every state.

## Accessibility

- **Contrast:** settings-native and privacy-ladder move footnotes to `tertiary` (#6E6E73), and assistant-first uses `--meta-ink` (the same value). All pass AA on the ground. Adopt this in `Tokens` for footers.
- **Targets:** Copy buttons and rows are 44 pt in all three. The assistant-first step-bar labels and the ladder's small "Off" / "Text" edge labels are about 11–12 pt. They are decorative, but they need to scale.
- **Dynamic Type:** the three-column diagrams (assistant-first `07b`/`07c`, the ladder everywhere) will not survive accessibility sizes without reflowing to a vertical list. Settings-native's list-only layout scales as-is.
- **VoiceOver:** settings-native marks radios and switches with roles. The ladder's numbered circles need labels ("Step 3, off").

## Steps

| Direction | To the intro | Setup screens | Notes |
|---|---|---|---|
| settings-native | 2 taps (row, Set Up) | 4 (intro, link, choices, connect) | Remove the off page as a stop when off. |
| assistant-first | 1 tap | 4, with a progress bar | Fewest, and the bar makes it feel shorter. |
| privacy-ladder | 1 tap | 4 (intro, camera, choices, connect) | Typing the code is a fifth screen. |

All three make the person type the server address on the code path. A code alone can't name the
server, so this is unavoidable, but the field should be prefilled from the last link and hidden
when the code is scanned.

---

## The final flow: best parts to combine

1. **Entry and off state:** settings-native's `AI Assistants · Off` row beside Privacy, and the Privacy row `AI assistants can read · Off`. No Ask-tab line. When off, the row opens the introduction directly (assistant-first's hop count).
2. **Introduction:** settings-native's title and plain example question, assistant-first's three short facts (text goes, audio stays unless you allow clips, you choose who reads), and assistant-first's "Off until you set it up." above `Link Your Server` / `Not Now`. No logos and no sample chat.
3. **Progress:** assistant-first's Link · Choose · Connect bar, in tokens.
4. **Linking:** settings-native's inline camera with "Or enter it" below (one screen, not two). Use assistant-first's `Scan New Code` as the primary action on the expired state, with settings-native's error copy.
5. **Choices:** settings-native's history-scope OptionCards ("All conversations, 214 … back to August 12" / "From today on"), then the two switches, both off. Nothing sends until Continue (fix the ladder's "Sending 412").
6. **Connect:** assistant-first's `05` screens whole: the address pinned with Copy, one card per assistant, `Copy Address and Open ChatGPT`, `Open Claude` with the server filled in, the Mac path, "Another assistant", and a green check by name only on server confirmation. Use neutral, distinct, token-colored tiles instead of brand marks.
7. **Linked state:** settings-native's order (status line with Last synced, then `Sync`, then Who can read, then Assistants can, then Unlink). Add the shipping "Sync is paused" state, assistant-first's Unlink footer ("connected assistants can still read it there"), and settings-native's correctly labeled scope row.
8. **Assistant detail:** the ladder's list including searches, plus assistant-first's "Added a follow-up" entries, then `Disconnect ChatGPT` with the ladder's consequence line.
9. **Privacy:** settings-native's three states as the base: the stance card unchanged in form, a headline naming readers, and the `AI assistants can read` row beside Siri & Spotlight. No diagram. Add the ladder's sentence "What they read becomes part of your chats with them." to the summary. Keep all five commitments, with the "never sold or shared" line corrected. Derive clip and follow-up wording from the switches.
10. **Tokens:** footers move to `tertiary`. Use iOS 26 glass back buttons, as assistant-first and the ladder draw them.
