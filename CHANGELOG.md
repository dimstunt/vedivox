# Changelog

What changed in Vedivox, newest first. The non-obvious controls are described in the guide
(Help → Vedivox Guide, or GUIDE.md next to this file in the archive).

## Unreleased

### Added

- **Listen finds unnamed regulars**: a voice that sounds like no one you know but speaks in three
  or more meetings shows up once, as "Unnamed voice in N meetings", with a fragment from each
  meeting. Naming it (or skipping it) applies to every meeting at once; a skipped voice comes back
  when it turns up in a new meeting. In `vedivox queue` such an item's id is its records joined
  by `+`, and `assign` and `skip` take it as is.
- **Reprocess says what it changed**: after each reprocess the log (`vedivox.log`) gets a line
  "Reprocess report for <meeting>": anonymous speech before and after, how much speech changed
  hands, and who moved to whom (`speaker_1 → Alice 4.7` minutes), largest first.
- **Split a voice that is two people**: in Listen, **X** gives each line of the voice to whichever of
  candidates 1 and 2 it sounds like; a line that does not clearly sound like one of them stays unnamed.
  From the command line: `vedivox queue split <item> --speaker <id> --speaker <id> [--margin 0.05]`.

### Fixed

- A voice the diarizer split in two no longer leaves half of it unnamed: a part that sounds like
  someone already recognised on the same track of that meeting gets their name.
- The speaker filter in the sidebar lists people, not every unnamed voice of every meeting, and a
  voice whose lines are all hidden no longer counts as taking part — there and in the speakers line of
  `vedivox meeting`, `list_meetings` and `get_meeting`.
- Reprocessing the only meeting a person speaks in no longer loses them: their lines there count
  towards their place among the candidates, so the new pass can still recognise them.

### Fixed

- **Meeting detection no longer loses a meeting app or browser that crashed and relaunched.**
  Calls in it went unnoticed until the app was quit and opened again, or detection was turned off
  and on in Settings ([#1](https://github.com/dimstunt/vedivox/issues/1)).
- **Turning meeting detection off during a call** no longer lets one last detection through, which
  could show "meeting detected" or start a recording right after the switch.

## 0.5.0 — 2026-11-19

### Added

- **Split, trim and merge meetings from the command line**, and undo each:
  `vedivox meeting split <id> --at <s> [--at <s>…]`, `vedivox meeting trim <id> [--from <s>] [--to <s>]`,
  `vedivox meeting merge <id> <id> […]`, `vedivox meeting undo split|trim|merge <id>`. They do what the
  buttons do; without `--yes` they say what would change and change nothing. The MCP server has them
  too, as `split_meeting`, `trim_meeting`, `merge_meetings` and `undo_meeting_edit`, with no such
  preview: these tools act at once.
- **All / Mic / System** in the transcript header (meetings with both tracks): show the lines of
  one track only. On **Mic**, **Exclude mic track** keeps the whole microphone track out of the
  transcript with one mark, and **Restore mic track** takes that mark away; the system track is
  never touched, and lines you hid by hand stay hidden.
- **The warning icon in the meeting list says what went wrong.** Hover the orange «!» or the red
  triangle next to a meeting to see the reason in plain words — a track that had sound but no
  speech, voices that could not be told apart, audio that could not be compressed, an empty mic
  recording — and what to do about it. Meetings processed before this version have no stored
  reason; the tooltip says so, and Reprocess fills it in. `vedivox show` prints the reason too
  (`status_reason` in `--json`).
- **A warning when the call is not being recorded.** If a call app has been playing sound for a
  minute while the system audio track stays pure silence — what macOS records when system audio
  access is off — a banner, a line in the menu bar menu and a notification say so during the
  recording, and the meeting is marked as needing attention afterwards.
- **Series page: filter meetings by speaker.** Click a speaker chip to list only the series'
  meetings where they speak; click more chips to narrow to meetings with all of them, click a chip
  again to drop it. Each chip shows in how many of the series' meetings that speaker talks. A
  speaker left linked to a meeting with none of its lines (they all went to someone else) no
  longer gets a chip.
- **Series page: unnamed voices share one chip.** `Speaker N` voices of different meetings are
  different people under the same label, so instead of a chip each they fold into one
  «N unnamed» chip at the end; a click on it lists the meetings that have any of them.
- **Speakers page: who else was there.** Above a speaker's meetings a «With» row lists everyone
  who spoke in them, with the number of shared meetings; click chips to keep only the meetings
  the speaker had with all of them.
- **The menu bar icon blinks when a recorded meeting ends** and, with the auto stop on, counts down
  to it («stop in 25s»); with Reduce Motion it stays highlighted instead of blinking. The menu then
  leads with **Keep Recording**, then Stop Recording, and the «Meeting appears to have ended»
  notification has Keep Recording as its only button (Stop moved to the menu). Keep Recording ends
  the reminders and the auto stop for this recording until the next call is detected and ends.
- **Processing N meetings…** under Start Recording in the sidebar while any meeting is being
  processed — a stopped recording, a reprocess or an import; a click opens the first of them. It
  replaces the old "Processing previous…" line.
- **Undo for speaker changes.** Edit → Undo (⌘Z) puts back the last speaker merge (Speakers
  screen, Similar voices banner, Edit Profile), profile rename, or Rename Speaker / Mark as Me in a
  transcript. The undo is refused once the meeting has been reprocessed since, or the same speakers
  or lines were changed some other way (a speaker deleted or marked as you, a line reassigned by hand);
  the refusal is shown on whatever screen is open.
- **`vedivox search --meetings`** finds meetings the way the sidebar does: a meeting matches when
  every word occurs somewhere in it — any line, the title or the description — and the answer is
  the meeting list of `vedivox list` (`--json` too). The MCP `search_transcripts` tool takes
  `meetings: true` for the same. Without the flag the search still returns lines.
- **`vedivox series merge <duplicate> <series to keep> --yes`** folds a duplicate series into
  another: its meetings move over and the duplicate is deleted. The series that stays keeps its
  name, calendar link and auto-rule, and takes the duplicate's only where it has none. Without
  `--yes` it says how many meetings would move and changes nothing.
- **`vedivox series apply-rules`** runs every series' auto-rule over the meetings without a series,
  the first matching series wins, as for a new meeting. Without `--yes` it only says how many
  meetings each series would take.
- **Delete Speaker.** Right-click a speaker on the Speakers screen → Delete Speaker…, or
  `vedivox speaker delete <id> --yes`: their lines in every meeting become unnamed (`Speaker N`), their
  listening verdicts are dropped and Vedivox stops recognising the voice. Your own record cannot be deleted.
  On the Speakers screen Edit → Undo (⌘Z) brings the speaker back with their name, voice, lines and verdicts.
- **`/vedivox-enrich` skill** for Claude Code ships in the archive and is installed by `install.sh`
  next to `/vedivox` and `/vedivox-live`: it checks a meeting's speakers, then writes a title and a
  description with timestamped stages and action items. In batch mode it never overwrites a
  meeting's existing description without asking.
- **Homebrew.** `brew install --cask dimstunt/tap/vedivox` installs the app and links `vedivox` and
  `vedivox-mcp`. The Claude Code skills are not part of the cask: it prints the two commands that
  install them as a plugin.
- **The skills install as a Claude Code plugin.** The repository is a plugin marketplace:
  `/plugin marketplace add dimstunt/vedivox`, then `/plugin install vedivox@vedivox`. The skills
  are then `/vedivox:vedivox`, `/vedivox:vedivox-live` and `/vedivox:vedivox-enrich`, and
  `/plugin marketplace update vedivox` brings the newer ones after a release. `install.sh` still
  copies them into `~/.claude/skills`.
- **Quick Search** (⌘K, Edit → Quick Search…): one field over meetings (titles, then transcripts),
  series, speakers, screens, Settings sections and menu commands, Start / Stop Recording included.
  ↑/↓ pick, Return opens, Esc or ⌘K again closes. The key can be changed in Settings → Shortcuts.
- **Edit → Reveal in Sidebar** (⇧⌘J) scrolls the meeting list to the open meeting and clears a
  search or speaker filter that hides it. The same is a round button in the bottom-right corner of
  the meeting list while a meeting is open.
- **Microphone priority.** Settings → Recording → Microphone priority replaces the single
  microphone picker with an ordered list of every input Vedivox has seen: drag to reorder, and each
  recording or dictation opens the first one that is connected. Rows show which mic is
  **Current** and which are **Unavailable**; new devices join at the end, virtual ones (Teams,
  BlackHole) after the real mics. Off by default; turned on, the list starts with the mic you
  had picked. The list is followed while a meeting is being recorded too: when the current mic
  disappears the next connected one takes over at once, and a higher one that gets connected is
  switched to after it has stayed connected for a few seconds. Dictation keeps the mic it
  started with unless that mic is lost.
- `vedivox audio compact` re-encodes older recordings (128 kbps) to the storage format of new ones
  (64 kbps, 24 kHz) and frees about 40 % of their space. Try `vedivox audio compact --dry-run`
  first: the re-encode cannot be undone, and transcribing a re-encoded meeting again is
  slightly less accurate. See the guide, "Disk space".
- A recording started through the command socket (`vedivox record start` or any
  script) shows a notification, "Recording started from the command line": any process
  running as you can drive Vedivox, and this is how you learn about a recording you did not
  start. README and SECURITY.md describe the trust model.
- **Live transcript.** While a meeting is being recorded, `vedivox live` shows what has been said so
  far, and `vedivox live --last 5m` only the last minutes (`--json` for scripts; the MCP tool is
  `get_live_transcript`). Made for asking Claude "what did they just ask?" in the middle of a
  call: the new `vedivox-live` skill covers that. Every line starts with who said it: `me`
  (microphone), the name of a speaker recognised by voice, `Speaker N` for a voice without a
  name, `others` for speech not told apart yet. Every minute Vedivox re-reads the last minutes of
  the recording with the pipeline of the final transcript — better text, and the speakers;
  `vedivox live --precise` does it on the spot. The text is preliminary, a few seconds behind, kept
  in memory and dropped when the recording stops; the final transcript is made as before. Speech marked "not in transcript" or said while muted in
  Zoom stays out. The window of the meeting being recorded shows the same text as it comes,
  laid out like the finished transcript, and follows the speaker until you scroll up to read. Off switch: Settings → Recording → Live
  transcript while recording.
- Settings → Meetings can start a recording when a meeting is detected
  and stop it when the meeting ends — two separate switches, both off by default (only
  notifications, as before). The auto stop warns first and waits a minute, so a room change or
  a reconnect does not cut the recording.
- **Listen** in the sidebar: unnamed voices that sound like someone you know, biggest first.
  Hear a fragment (← → or the arrows next to it step through the voice's fragments), compare with
  each candidate's own voice, and answer with one key — this is
  candidate 1/2/3, a new person, someone else, or skip. The whole voice of the meeting moves at
  once and both voice profiles are recalculated. A meeting with such voices shows
  "N voices to check" above its transcript. Coming back to Listen shows the list of
  your last visit at once and refreshes it behind; a run of changes costs one refresh.
- Experimental: muting yourself in a Microsoft Teams call (the new Teams app, English
  interface) hides your mic speech the same way as in Zoom, under the same setting.
  `vedivox mute-debug` shows what Vedivox reads from Zoom and Teams right now.
- Hand-made speaker fixes survive Reprocess: moving lines to a speaker (in the transcript, in
  Listen or with `vedivox segment set`) records a verdict for that stretch of audio, and every
  later processing gives the lines back to that speaker.
- `vedivox queue` lists the Listen voices; `vedivox queue assign <item> --speaker <id> | --new <name>`
  and `vedivox queue skip <item>` decide them. `vedivox segment set <meeting> --from --to --speaker`
  moves every line of a time range in one call. `vedivox meeting pin-speakers <id> --yes` pins a
  meeting's current named speakers before a reprocess. `vedivox marks` shows verdicts with the
  speaker.

- Vedivox tells you when a newer version is out: once a day it asks GitHub for the latest release
  (one anonymous request) and, if there is one, shows Vedivox → Vedivox X.Y.Z Is Available… with the
  release notes. It never downloads or installs anything. Off switch and Check Now in
  Settings → About.
- Help → Star Vedivox on GitHub, the same link in About, and a one-time card in the main window
  after your fifth processed meeting (Not Now hides it for good).
- The release zip and `install.sh` now include `vedivox-mcp`, the MCP server, next to `vedivox`.
- `vedivox transcribe <file|YouTube URL>` prints a diarized transcript of a one-off recording
  (a voice message, a lecture) without saving anything: no meeting appears, no speakers are
  created, voice profiles stay as they were. Known speakers are still recognized by name.
- What you say while muted in Zoom stays out of the meeting transcript, read from Zoom's
  own mute state; toggle in Settings → Transcript. Needs the Accessibility permission, now
  also asked for during onboarding.
- Dictation pauses whatever is playing (Spotify, Music, a video in the browser) and resumes it
  the moment you stop speaking. Settings → Dictation → While dictating also offers Mute sound
  or Do nothing.
- Dictation made while a meeting records stays out of the meeting transcript; a "Dictation"
  plaque with the dictated text marks the spot.
- Merge Meetings is back: select two meetings in the sidebar (⌘-click) and right-click.
  Undo Merge in the transcript header splits them again.
- Meeting detection recognizes Microsoft Teams calls (the desktop app); toggle in
  Settings → Meetings.
- Meeting detection recognizes Yandex Telemost calls, in the desktop app and in a browser tab
  (`telemost.yandex.ru/j/…`, `telemost.360.yandex.ru/j/…`); one toggle in Settings → Meetings,
  off until you switch it on. Brave's tabs are now checked too, and a Meet link inside another page's
  address (a search result) no longer counts as a Meet call.

- **Chopped call audio is caught during the recording.** When the other participants reach the
  recording in short pieces with silence in between (a rare Core Audio fault, seen once for half an
  hour of a Zoom call), Vedivox restarts its system audio capture by itself. If that does not
  help after three tries, a banner, a menu bar line and one notification ask you to switch the
  speaker in the call app to another device and back; the meeting is marked "!" afterwards, with
  the reason in its tooltip.

### Changed

- **Signed and notarized.** The release is signed with a Developer ID and notarized by Apple, so
  Vedivox opens like any other app: no Open Anyway in System Settings, no `xattr`.
- **A sign of its own.** The app icon and the menu bar icon are the Vedivox V: a yellow stroke
  for you, a light one for the others, the red recording dot under the tip. The menu bar icon
  shows the state with the same parts: a ring when idle (the right stroke dimmed until a call is
  detected), a dot while recording, red while an interval is excluded, amber during the
  countdown to the auto-stop, the left stroke alone while dictating, an arc while transcribing.
- **Slower and faster are ⌥[ and ⌥]**, set in Settings → Shortcuts with the same recorder as every
  other shortcut. A key you had changed moves over with ⌥ added (P becomes ⌥P); one with no key
  on the US layout goes back to the default.
- **The meeting header no longer shows a language label.** It read RU for everyone and had no
  effect on recognition.
- **Speech models come in fixed, checked versions.** Vedivox used to download whatever version of
  the recognition models was published last, so a change on the server could quietly change
  your transcripts. Now each model is fetched at the exact version Vedivox was tested with.
  Models already on your Mac stay: the first launch after the update checks them against those
  versions — this needs the internet once — and downloads nothing.
- **The welcome steps ask for every permission up front.** The System Audio step now really
  brings up macOS's question (before, it came only with the first recording) and shows a check
  mark only once Vedivox has heard system audio; with nothing playing it says it will be
  confirmed by the first recording with sound. With call detection on, the last step can ask
  the open browsers for tab access right away and names the ones macOS will ask later.
  Settings → Privacy & Permissions → System audio has a Check button for the same question.
- Action Items are gone from the app: the meeting inspector had a section for them that nothing ever
  filled. Action items written into a meeting description stay where they are.
- The `extracting` meeting status is gone from `vedivox list --status`, `vedivox status` and the MCP
  `list_meetings` tool: no meeting reached it any more. A meeting a crash left there reads as
  `diarizing` and is recovered on the next launch, as before.
- Settings → Storage: every row shows its place as `~/…` and its size, Logs included, with at most one
  line of explanation; the buttons all read Show in Finder.
- Settings → Privacy & Permissions: every permission has a status mark (allowed, not allowed, or a
  neutral one for not asked yet or not reported by macOS) in one column, a button in the next, and
  its caption starts with the status. Microphone, Calendars and Notifications that macOS has not
  asked about yet get **Allow**, which shows macOS's own prompt; everywhere else the button is Open
  Settings. Calendars checked in Settings → Meetings without calendar access are now said out loud
  on both screens instead of quietly doing nothing.
- `vedivox reprocess`, `vedivox speaker merge` and `vedivox series delete` now need `--yes`, like `vedivox meeting delete`:
  without it they name what would change and exit 1, so a mistyped id no longer rebuilds a
  transcript or deletes a speaker or a series.
- `vedivox search --help` and the MCP `search_transcripts` description say what matches: transcript
  lines that contain every word of the query (as prefixes); titles and descriptions are not
  searched. The sidebar search, which matches whole meetings, is the place for that.
- **Settings keep a readable width**: on a wide or full-screen window the settings column stops
  at about 720 points, so a label and its switch read as one row instead of sitting at opposite
  edges. The column stands in the middle of the space right of the section list.
- **Esc in a search field** clears the query first; the next Esc leaves the field (meeting search
  in the sidebar and search in the transcript, which ignored Esc). The Dictations badge counts
  every dictation, not only the 200 the history loads. A quiet call track no longer writes an
  `[ERROR] Diarization failed … No speech detected` line to the log.
- **Trim from the keyboard**, like Split: ← → move the chosen bound by a second, ⌥← ⌥→ to the
  previous or next segment (the start to segment starts, the end to segment ends), and **Tab**
  or the Start / End switch picks which bound moves. The bound that moves is drawn like
  Split's cut.
- **Meetings that failed to process are offered again.** When meetings are left unprocessed —
  for example recorded on a first launch before the speech models could download — a banner
  names them with **Reprocess** (one at a time) and **Not Now**. Reprocess leaves alone a
  meeting you have processed yourself in the meantime, and a meeting whose processing crashed
  Vedivox is not in the banner (its own screen can still reprocess it). The failed meeting's screen
  now says why it failed when Vedivox knows (in this run), and the "Could not load models" banner
  goes away once the models load through a recording or a reprocess, not only through Retry.
- **Reprocess shows itself.** While a meeting is being processed again, its Reprocess button turns
  into a spinner with "Processing…" — the old transcript stays on screen until the new one is
  ready — and when it ends, the header says "Processing finished 03:12" (or "Processing failed")
  next to the date until you open another meeting. A reprocess started from the window that fails says why in an alert; one that failed
  before replacing anything says the transcript is unchanged.
- Small wording fixes in the window: "1 meeting" instead of "1 meetings" on the Speakers and
  Series screens; an unnamed voice reads "Speaker 3" instead of `speaker_3` in the transcript and
  its speaker filter; the live transcript says "You" and "Others" (`vedivox live` keeps `me` and
  `others`). The meeting toolbar's scissors button is now "Trim / Split" and the pencil next to
  "Speaker:" is labelled "Edit speakers". Timecodes in the edit list read `0:00—0:14`, like the
  rest of the transcript. The empty main window on first launch shows how to record, import or
  drop a file.
- Settings are regrouped. Recording keeps the microphone, the live transcript and the apps left
  out of system audio; meeting detection, its reminders and the calendars moved to a new
  **Meetings** section; what is hidden from the transcript (muted in Zoom or Teams, "Not in
  transcript", foreign voices) and speech recognition, including the diarization choice that
  was in Experimental, are now **Transcript**. Updates moved to About, Debug logging to
  Storage. Every setting keeps its value.
- Settings → Transcript lists the languages Vedivox recognizes (about 25 European ones, detected
  automatically). "Remind every" is now "Reminder interval" and says it also times the auto
  stop; foreign voices on the mic say they need My Voice; the version in About carries the
  one-line description.
- New installs start with the monochrome Mono palette, and only OBS in Settings → Recording → Not
  recorded in system audio. The other palette is now called Ink & Yellow. An existing install
  keeps the palette and the list it had.
- Settings → Privacy & Permissions shows a status for System audio and Automation too. System
  audio gets a check mark when a recording of the last 30 days heard speech on the system track
  (macOS has no call that reports this grant); Automation lists, per browser, whether Vedivox may read
  its tabs, without ever asking. Open Settings stays next to both. When macOS does not say, the row
  shows a grey question mark, so an unknown status no longer looks like a refusal.
- Settings → Meetings shows the per-app switches, the reminders and the calendars only while
  meeting detection is on, instead of a block of dimmed rows.
- Settings → Dictation: the dictation shortcut can be changed right there, a new Accessibility
  row says whether Vedivox may type the text (and opens System Settings when not), and "Live text"
  is now "Draft while you speak", so it is not confused with the meeting's live transcript.
- Settings → Shortcuts keeps all the player keys in one Player group, lists the fixed keys it
  was missing (Esc in the transcript and in Speakers, the arrows in Split, ⌘, for Settings)
  under Window, and Restore Defaults now also resets the player keys and the seek step.
- Settings → Storage counts the database with its write-ahead log (a new library no longer
  shows "Zero KB") and shows the speech models (about 1.2 GB, in FluidAudio's own folder, not
  removed with Vedivox) and the automatic backups, each with Open Folder.
- Settings → Privacy is now Privacy & Permissions: one list of what macOS lets Vedivox do —
  microphone, system audio, Accessibility, calendars, notifications, automation for Google
  Meet — each with Open Settings. The Telemetry and Crash reports switches are gone: they
  were always off and could not be turned on.
- New default global hotkeys: ⌘⇧1 starts and stops a recording, ⌃⇧⌘1 is "Not in transcript"
  (they were ⌃⇧⌘2 and ⌘⇧1). An existing install keeps the keys it already has; change them in
  Settings → Shortcuts.
- Vedivox is now licensed under GPL-3.0-or-later instead of MIT; the licence text ships in the
  release zip. Code changes from outside are not accepted for now, issues are welcome.
- The open meeting, the segment under the playhead and the current choice in a list are a
  shade darker, so a row under the pointer next to them no longer looks selected too. Speaker
  names in the light themes are a touch darker to stay readable on that fill.
- The "meeting appears to have ended" reminder comes sooner (about 15 s after the call instead
  of 35–40 s) and repeats every minute instead of every 3 minutes, but not while your mic hears
  speech. Both times are settings.
- Split opens with the cut at the start of the segment you are listening to, and the cut moves
  without the mouse: ← → by a second, ⌥← ⌥→ by a segment (buttons in the sheet do the same).
- Help → Vedivox Guide and What's New open in a Vedivox window, formatted, instead of the raw
  Markdown file in whatever app your Mac opens `.md` with. Meeting descriptions follow the
  same rules: a list item continued on an indented line stays one item, and a single line
  break inside a paragraph reads as a space.
- Building from source no longer needs the author's signing team: `make install TEAM=-`
  signs ad hoc, `TEAM=<your team id>` signs with your own. Without `TEAM`, a machine that lacks
  the author's certificate now signs ad hoc on its own, a missing `xcodegen` stops the build with
  the install command, and dependency versions are pinned by the committed `Package.resolved`.
- The starter term vocabulary created on first launch is a short neutral set (Docker, GitHub,
  dashboard, milestone, backlog, Kubernetes, PostgreSQL). An existing `vocabulary/terms.txt`
  is left as it is — add your own terms there.
  signs ad hoc, `TEAM=<your team id>` signs with your own. The starter term vocabulary
  created on first launch no longer carries a company name; an existing
  `vocabulary/terms.txt` is left as it is.
- A speaker's voice in new and reprocessed meetings is built from their own speech: every phrase
  keeps the voice of its own stretch of audio instead of a copy shared by everyone the diarizer
  grouped together, and a meeting's voice is weighed by seconds of speech.
- Links that import a file or reprocess a meeting are no longer handled: a link can come from a
  web page or a pasted note, and these changed data without asking. Use `vedivox import` and
  `vedivox reprocess`; links to a meeting (`vedivox://meeting/…?t=…`) work as before.
- `vedivox list --from/--to` (and the MCP `date_from`/`date_to`) mean your local day; a value that
  is not `YYYY-MM-DD` is refused. `vedivox speakers` prints full ids, the form the speaker commands
  take. A refusal for bad parameters exits 64, and `vedivox import` exits 2 for a file the app
  cannot find.
- The starter term vocabulary created on first launch carries no live terms: it is a set of
  instructions with neutral examples (Docker, GitHub, dashboard, Kubernetes, PostgreSQL) to
  switch on. An existing `vocabulary/terms.txt` is left as it is — add your own terms there.
- In Zoom, mic speech while you are not muted is no longer hidden as a foreign voice: it went
  into the call, so it stays in the transcript even when Vedivox did not recognise your voice.
  Other meeting apps work as before.
- Two palettes in Settings → General → Palette: Ink & Yellow (ink blue, cream text, yellow
  buttons, search hits and selection, cyan focus) and Mono (the original monochrome). Each has
  a dark theme and a muted light theme — a warm grey instead of near-white. Speaker names are
  a shade darker in the light themes so every color stays readable. The Series, Speakers and
  Settings lists sit on the content background and no longer merge with the sidebar.
- Start Recording is the regular primary button with a red record mark; solid red is left
  to Stop, so red on screen means a recording is live.
- Drop-down choices (Settings, the transcript's speaker filter, the series in the inspector and
  in Edit Meeting, playback speed) open a list in Vedivox's colors instead of the system menu with
  its blue highlight. Arrow keys move through it, Return picks, Esc closes.
- New app icon: a V of two sound bars, yellow and paper, leaning in on an ink plate, with the
  red recording dot where they meet.
- Timecodes, counts, row subtitles and other metadata are darker and readable in both
  themes; speaker colors keep the same brightness across hues (yellows no longer glare,
  blues no longer sink).
- One look for every banner (permissions, model loading, similar voices), every text field,
  every section header and every counter; the Record and Stop buttons, links and icon
  buttons no longer use the system button styles.
- Selected transcript segments get a solid outline, so they no longer look like the segment
  under the playhead. The window frame around the sidebar and the toolbar no longer take on
  the wallpaper tint. All text uses one type scale (small captions are a point larger).
- Undo Trim, Undo Split and Undo Merge are available for 7 days. The copies of the
  original audio they keep are deleted after that and no longer pile up (they had reached
  about an eighth of all audio).
- Old automatic database backups are cleaned up on every launch, not only after an update
  that changes the database: the newest three stay. Copies you made under other names are
  never touched.

### Fixed

- Bluetooth headphones connecting in the middle of a recording no longer silence your
  microphone for seconds when you record from another one. Vedivox now opens the microphone
  you chose directly, without going through the system default input: a recording or a
  dictation from a USB or built-in mic no longer waits for headphones that macOS made the
  default input, and no longer switches them into headset mode for a moment.
- **Undo Split gives the meeting its length back.** It used to take the end of the last line, a few
  seconds short of the recording, and the next split carried the error.
- **Undo Trim after a split no longer brings the cut-off part back into the first part.** A split now
  drops the undo of an earlier trim, as a trim already dropped the undo of a split.
- **A merge interrupted midway no longer leaves two half-merged meetings.** The database changes in one
  step, and a merge stopped by a crash or a quit is undone or finished on the next launch, with
  Undo Merge available.
- **Undo Merge takes back the tags the merge brought.** The later meeting's tags used to stay on
  the earlier one as well. Merges made before this version still leave them.
- `install.sh` keeps the signature `vedivox` and `vedivox-mcp` come with: from a notarized zip they
  stay signed with the Developer ID instead of being re-signed ad hoc.
- **A recording no longer stays deaf to the call.** Mid-recording, the system audio capture could
  stop hearing the call app and record digital silence for the rest of the meeting (25 minutes of a
  Zoom call on November 19), while everything looked normal. When the call app plays but the system
  track has been pure silence for a minute, Vedivox now restarts the capture in place, in the same
  meeting; about 0.1 s of the track is filled with silence. In a real silence it waits longer each
  time (up to 10 minutes between restarts), so a long break costs nothing.
- **System audio no longer shows Allowed on old evidence.** Settings → Privacy & Permissions
  marked it allowed after any recording of the last 30 days with the other side in it, though such
  a recording does not prove that macOS grants the permission now. Now only a recording Vedivox
  has just made, with sound on the other participants' track, confirms it; until then the row
  says Not confirmed yet.
- The right-click menu on a meeting in the sidebar opens sooner: the list builds only the rows on
  screen instead of every meeting, so the menu no longer waits on the whole library.
- **Trim no longer keeps speakers who were cut off.** A speaker whose lines all fell outside the
  kept range stayed on the meeting (in its speaker list, in the Speakers and Series counts); now
  they leave it, as after a split.
- **Speakers and Series** no longer open on "No Speakers" / "No Series" and then redraw: a return
  shows the list you left at once and refreshes it behind. **Listen** builds its queue once shortly
  after launch, so the first visit shows the list instead of waiting about a second.
- **Trim.** "keeps N seg., deletes M" counts what the trim really does: a segment a bound cuts
  through is kept (shortened), not deleted. Trim to a range inside one long segment is no longer
  refused.
- **Delete Meeting** picked in Quick Search (⌘K) or clicked in the File menu asks about the
  meeting even while a text field with text has focus; it used to erase that text instead. ⌘⌫
  itself still deletes text in the field.
- **Series.** Delete asks first and says how many meetings will be unlinked. A series that fails
  to save keeps its sheet open with the error, and its auto-rule is not applied. "Apply to
  existing meetings" shows how many meetings the rule takes, and the sidebar shows their new
  series right away.
- **Speaker names.** Edit Profile no longer saves a blank name, a blank nickname or a `speaker_N`
  name; a name another speaker already has offers to merge into them. Renaming a speaker from a
  transcript line moves only that speaker's lines, and naming an `UNKNOWN` run (or marking it as
  you) changes only that run. A failed speaker merge says so instead of closing silently, and
  merged lines carry the speaker's display name.
- First-launch details: when microphone access was refused, onboarding now has an **Open System
  Settings** button (macOS asks only once). The `<unk>` → «ё» fix applies only inside Russian
  words, so a letter the model does not know in another language is no longer turned into «ё».
  INSTALL.md says where the speech models live (`~/Library/Application Support/FluidAudio/Models`,
  about 1.7 GB) and that removing Vedivox leaves them.
- Live transcript no longer makes a long recording ever more expensive: the window applied the
  vocabulary to the whole text again every second, even with the main window closed. Each turn
  now goes through the vocabulary once, and nothing is read while the window is closed, hidden
  or covered.
- A microphone that does not open within 15 seconds no longer leaves a recording half-started
  forever: the recording reports an error (and `vedivox record start` answers), the next attempt
  starts afresh, and a dictation cancelled while its input was opening frees the hotkey within
  the same 15 seconds. Seen with BlackHole as the input right after a cancelled dictation.
- Quitting Vedivox while it recovers an interrupted recording no longer marks that meeting as an
  error on the next launch: the recovery runs again. Only a recovery that crashed the app gives
  up on the meeting (Reprocess is still available).
- Speaker assignments made on meetings transcribed by older versions (before the microphone and
  call tracks were kept apart) survive Reprocess: your own lines go back to you on the microphone
  track, everyone else's on the call track. They used to be dropped.
- Trim, Split and Merge now cut the echo-suppressed microphone track too. The player plays that
  track when it exists, so after a trim it kept the old length and the microphone sounded out of
  step with the transcript. Undo Trim also restores the meeting's start time and length.
- Switching the palette or the theme repaints the meeting, Listen and Dictation screens at once;
  they kept the previous palette's ground until Vedivox was restarted.
- `vedivox speaker merge` (and the MCP `merge_speakers` tool) with an unknown source id answers "not
  found" and merges nothing; it used to skip that id and report success. Exporting a transcript
  over the command socket reports a cancelled save panel or a failed write instead of success.
  `vedivox audio compact` right after Vedivox starts sees every meeting, not an empty list. Deleting
  meetings removes them from the database before their audio goes to the Trash, so a failed delete
  no longer leaves meetings without sound.
- `vedivox audio compact` no longer puts back an untrimmed copy over a track that was trimmed while it
  was being re-encoded: that track is reported as failed and kept as trimmed.
- `vedivox import "~/talk.mp3"` and `vedivox transcribe` with a quoted `~` path find the file (the MCP
  `import_file` tool too). `vedivox import` and the MCP import tools work before Vedivox has created its
  database, and a missing database is reported once instead of twice. vedivox-mcp answers `ping`,
  stays silent on notifications (a `tools/call` without an id no longer runs), answers an
  unreadable line with `"id": null`, refuses a fractional or huge `segment_id`/`mark_id` instead
  of crashing or picking another row, and treats a negative `limit` as 1 instead of "no limit".
- Quitting Vedivox (⌘Q, log out, restart) during a recording stops it first: both tracks are closed
  and the meeting gets its end time, so the transcript is made on the next launch instead of
  starting from a broken recording. Quitting while a meeting is being processed asks first,
  because processing starts over on the next launch.
- Settings → Recording → Microphone priority marks a microphone **Current** or **Unavailable**
  as soon as it is plugged in or out, without leaving the section.
- Quitting Vedivox (⌘Q) during a dictation asks first, since the text will not be inserted — during a
  meeting recording too, where Quit then saves the dictation and stops the recording; a logout
  or restart does not ask. Music the dictation paused resumes on the way out instead of staying
  paused.
- **A dictation cut short is no longer lost.** Quitting during a dictation (after the question,
  on log out or restart, or when Vedivox is killed) keeps its audio in Dictations as "Not
  transcribed yet"; the next time Vedivox opens it transcribes it there. Nothing is inserted
  anywhere — copy the text from the history. If that transcription fails, the re-transcribe
  button on the entry tries again. Such an entry keeps its audio until it is transcribed.
- Dragging a row in Microphone priority moves it: the other rows make room while you drag, and
  the cursor no longer shows the green copy "+". The dragged row slides over its neighbour instead
  of showing through it, and the row numbers no longer blur into each other mid-move.
- Meeting search in the sidebar finds a meeting when every word of the query occurs anywhere in
  it — in different lines, in the title or in the description. It used to need all the words in
  one line, ignored the description, and a common word could hide meetings behind a cap of 200
  lines. `vedivox search` still returns lines that contain every word.
- Help → Vedivox Guide and What's New draw `---` as a line, keep the text to a readable column on a
  wide window and leave room between sections.
- Merging a meeting that a quit or a crash left without a duration no longer lays the later
  meeting's lines over the earlier ones; such a meeting gets its duration from its audio.
- A voice heard only in the right channel of a stereo track is transcribed: two channels were
  brought to one by keeping the left, so such a voice reached neither the live text nor the
  final transcript.
- Settings explain what Density and the Calendar list do: Density spaces the meeting list;
  a checked calendar names a detected meeting and links its series, it does not drive detection.
- Settings → General → Density is gone: the meeting list always uses the compact rows, without
  the description preview line. A stored Density setting is ignored.
- Settings no longer show three switches that did nothing: Default transcription language
  (speech recognition finds the language itself), Record microphone and Record system audio
  (both tracks are always recorded).
- Settings captions that were wrong: ⌘⇧1 works while you dictate; the mute switch is now
  "Hide speech while muted in Zoom or Teams"; ⌘⌫ in a text field deletes text only when there
  is some before the cursor; Transcription → Diarization shows the pipeline actually selected in
  Experimental; Privacy says Vedivox downloads its models and checks GitHub for updates.
- Settings → Recording → Detect meetings automatically no longer shows "on" while detection is
  off: on a Mac that never answered the onboarding question it is now shown off, as it is.
- A browser that does not let Vedivox read its tabs (Automation refused, or the browser hung) is now
  named in `vedivox.log`, once per change, with the reason; Google Meet and Telemost calls in it
  used to go unnoticed without a word. A browser that refused is asked once a minute instead of
  every 5 seconds.
- A track with no recognised speech no longer leaves an empty transcript row spanning the
  whole recording; such rows already in the database are removed on the first launch.
- After Split the first part no longer lists speakers whose segments all moved to the second
  part; such leftovers from earlier splits are cleaned up on the first launch.
- Two stops at once (the menu and a notification, or two `vedivox record stop`) stop the recording
  once: the second `vedivox record stop` exits with 1, and the meeting is no longer marked as
  needing attention for an empty capture.
- In the light themes, transcript segments in edit mode have the same thin outline as in
  the normal view.
- The sidebar preview of a meeting description shows its first line of text, not raw
  Markdown: headings are skipped, and list markers, bold and links are dropped.
- Without the Accessibility permission, cancelling a dictation with Esc also closes whatever
  Esc closes in the app underneath. The dictation indicator now says so (once per launch)
  instead of leaving it to the log. The indicator is no longer redrawn once the microphone
  opens, so its clock keeps counting from the key press instead of starting over.
- After you allow Vedivox in Accessibility, the "Dictation can't insert text" banner says that a
  restart is the only step left: macOS applies the permission to inserting text only after Vedivox
  is reopened. Reading the Zoom and Teams mute state and keeping Esc from the app underneath
  start working at once, without a restart.
- Creating a series whose name already exists (case ignored) no longer adds a duplicate. The
  New Series window says the series already exists and keeps what you typed, so the rule, icon
  and description are not lost; `vedivox series create` and the sidebar's new series answer
  with the existing one.
- A call that was detected but never recorded no longer leaves an empty series behind: the
  calendar series is created when the recording starts.
- A new recording or import joins the series whose auto-rule matches its title right away,
  not only after the meeting is renamed.
- `vedivox import <YouTube URL>` and `vedivox transcribe <URL>` run yt-dlp in their own download
  folder. Before, yt-dlp picked up a `yt-dlp.conf` from the directory you ran the command in,
  and a line such as `--exec` in a cloned repository's config ran as a command.
- `vedivox` and `vedivox-mcp` run on macOS 14.4, like the app; the binaries in the archive needed 15.
- A meeting id with `%` or `_` in it no longer matches other meetings (`vedivox meeting delete %`
  could resolve to the only meeting in the library).
- `vedivox import --date YYYY-MM-DD` accepts a day on which the clocks go forward at midnight
  (Cairo, Beirut, Santiago, Havana): it was refused as an unreadable date.
- Dates printed by `vedivox` and the MCP tools are Gregorian even when the system calendar is
  Buddhist or Japanese.
- A speaker cannot be renamed to nothing and a meeting title cannot be blanked from the CLI or
  MCP; an MCP client that sends `null` for a field no longer clears it. `vedivox mark` refuses a
  time that is negative or not finite — such a mark broke `vedivox marks` for that meeting.
- Importing through a symbolic link stores the file itself, not a link to it.
- Building from a source archive without git history no longer produces an empty build number.
- `install.sh` stops before touching anything when `/Applications` is not writable and names
  `VEDIVOX_APPS_DIR` as the way out.
- Two people with similar but distinguishable voices no longer freeze each other's voice
  profiles. A profile update is now refused only when the speaker's meetings really cannot be
  told apart from another confirmed speaker, and the refusal names that speaker and the
  meetings to check (`vedivox speaker rename|merge|detach` print it).
- `vedivox import <YouTube URL>` and `vedivox transcribe <YouTube URL>` download into `$TMPDIR` when it
  is set, so they work under a sandbox that allows writing only there; a download folder that
  cannot be created is reported by its path instead of a missing `stderr-….log`. Each download
  gets its own private folder, removed as soon as Vedivox has taken the file.
- `vedivox feedback` works under such a sandbox too: it stages the archive in `$TMPDIR`.
- When the CLI is not allowed to reach Vedivox's socket (a sandbox), it says so and exits 3 instead
  of reporting "app: not running" and trying to launch a second copy; a launch the system refuses
  asks you to open Vedivox by hand.
- Music or a notification sound in the system audio, with nobody speaking, no longer marks the
  meeting as needing attention: an empty transcript is expected when there was no speech.
  Speech that produced no transcript is still flagged.
- The transcript's Speaker filter marks a speaker whose lines are all hidden ("— hidden"), and
  a foreign voice still waiting for your answer repeats the question ("participant or
  background?"), so picking them no longer shows an empty transcript with no hint why.
- Your own speech is no longer hidden as a foreign voice when Vedivox narrowly fails to recognise
  it: a voice on your microphone that stayed unnamed but resembles you more than anyone else
  is kept in the transcript as an unnamed speaker. Applies to meetings processed or
  reprocessed from now on.
- On the microphone track, only your own voice is still recognized at the old, looser threshold;
  anyone else heard on your mic needs the same confident match as on the call audio, so a guest
  or your own speech no longer lands under a lookalike's name.
- A voice that only resembles a known speaker stays an unnamed speaker_N instead of getting
  that person's name; very short voices and the last seconds of a recording no longer get
  someone else's name either.
- Two different known speakers with the same name in one meeting no longer merge into
  one: the second is labeled “Name (2)” (or the next free speaker_N for auto-named ones).
- Theme → System follows macOS again after Light or Dark was picked; the window used to keep
  the last forced theme.
- Search hits in the dark Ink & Yellow theme are a shade lighter, so the text on them stays
  readable on the segment under the playhead.
- Merging meetings checks the joined audio against the originals (length, and sound where
  there was sound); a join that comes out short or silent is refused and both meetings stay
  as they were.
- The last word before a pause no longer stretches its transcript line over the whole
  silence (a "?" lasting a minute and a half, a line of a few words lasting 20 minutes), and
  no longer hands that word to whoever speaks after the pause. Applies to new recordings and
  to meetings you reprocess.
- An in-person meeting recorded through one microphone, with nobody on a call, no longer
  turns into an empty transcript: when the system audio has no speech at all, the voices on
  the mic are kept as participants instead of being hidden as foreign voices.
- Vedivox no longer crashes now and then when a dictation is cancelled with Escape.
- The dictation panel appears the moment the hotkey is pressed, not after the microphone has
  opened (up to a few seconds with an iPhone as the mic). Escape already works then, and a
  second press while it opens is ignored instead of starting the dictation again.
- ⌃⇧⌘2 starts and stops a meeting recording during dictation too; it used to be ignored
  while dictating.
- A microphone that drops out or will not start (a USB mic after it dropped and came back)
  no longer stops the recording or loses your voice: Vedivox records from the built-in mic
  (or the system default input) meanwhile and switches back once the mic is plugged in again.
- A microphone unplugged in the middle of a recording is left the moment it disappears, not a
  second later when the silence is noticed, and a microphone that goes quiet when headphones
  connect is restarted sooner — the hole in your track is shorter. Each switch is one
  `Mic switch:` line in the log: from which mic to which, why, and how long the hole was.
- Merging two meetings keeps the audio at the compact storage size instead of
  re-encoding it at about 250 kbps.
- Dictation no longer leaves a dead keyboard hook in macOS after each use. They piled up
  while Vedivox kept running and could make typing and scrolling lag in every app.
- Reopening the main window (or switching the palette) while a meeting records no longer
  treats that recording as a crashed one: Vedivox used to "recover" it on the spot, compress the
  unfinished audio and delete the files it was still recording into, so everything said after
  that moment was lost. The recording and "not in transcript" hotkeys also no longer fire
  twice after the window was reopened.
- A recording interrupted by a crash, a quit or a restart keeps the other side of the call:
  on the next launch Vedivox repaired only the microphone file, so the call audio read as empty,
  nobody but you made it into the transcript, and the meeting ended in "Processing Failed".
  The repair no longer loads the whole file into memory and no longer crashes on
  recordings over 4 GB.
- A meeting whose processing was interrupted after its transcript was saved (a quit or a crash
  during speaker matching or audio compression) no longer stays "in progress" forever with
  Reprocess and delete refused: it is processed again on the next launch. If that recovery
  dies too, the meeting is marked failed instead of being retried, and crashing, at every launch.
- Renaming or reassigning a speaker in one meeting no longer deletes other people you named,
  or your own voice profile, when they currently have no meetings (their only meeting was
  deleted or reprocessed, or you had just recorded your voice).
- Undo Merge works: it used to fail every time, after it had already put the first meeting's
  original audio back — leaving one meeting with the full transcript over half the audio and no
  second meeting. The meetings are now separated in the database first and the audio is swapped
  last; a failure on the way leaves the merged meeting as it was.
- Merge Meetings no longer throws audio away: it is refused when the later meeting has a track
  that cannot be joined (the earlier meeting has no system audio, or a recording is not compressed
  yet), and while either meeting is still being recorded or processed. It used to skip such a
  track silently and then delete it with the later meeting's folder. The same goes for a later
  meeting that still holds its imported file because the import never finished: reprocess it
  first.
- Undo Trim and Undo Split are no longer offered on a merged meeting (undo the merge first): they
  restored audio saved before the merge and erased the second meeting, audio and transcript.
  Undoing a second merge into the same meeting now returns the result of the first one instead of
  the very first meeting alone, and trimming or splitting a merged meeting removes its Undo Merge,
  which would have cut at the wrong place.
- Splitting a meeting can no longer damage it when it fails halfway (a track that will not cut, a
  full disk): the split used to delete each track before writing its halves, so a failure left the
  microphone already cut, the call audio missing and no Undo. Now both tracks are cut first and
  nothing is replaced until everything has succeeded. A meeting that was split before can be split
  again.
- Trimming a meeting can no longer leave it half-trimmed: every track is cut first, and the
  audio, the transcript and the "not for transcript" marks change together or not at all. A
  failure on one track used to leave the microphone cut under call audio and a transcript that
  were not, every line off by the trimmed start. A line that crosses the cut now begins at the
  cut instead of before the start of the meeting.
- Merging meetings keeps what the later meeting carried: its description is added to the first
  one's, its tags come along, and Undo Merge gives each meeting its own description back. They
  used to be deleted with the later meeting.
- When a split, trim, merge or their undo fails, Vedivox says so and why; it used to look as if the
  click had done nothing, with the reason only in the log.
- A meeting that is still being recorded or processed can no longer be deleted from the window
  (the command line already refused): its audio went to the Trash while the recording kept running
  with nothing left to stop.
- The first launch after an update no longer looks like an empty library. While Vedivox copies the
  database and applies the new version's changes — a minute or more on a large library — the
  window says "Updating your library…" in a banner, in the sidebar and in place of the section
  you opened. It used to show an empty list everywhere, and Speakers sat blank for as long as
  the update took.
- A list is no longer left empty, with an error in the log, because the view that asked for it
  went away while it was loading: the meeting list, Speakers and the Listen queue finish
  loading regardless.
- Reprocess no longer leaves a meeting empty when it fails: the old transcript, with your edits,
  stays in place until the new one is ready and is swapped for it in one step. A run that fails
  on the way (no models, a track that will not convert, a full disk) leaves the meeting as it
  was; the same holds for a reprocess cut short by a crash. A meeting cannot be reprocessed twice
  at the same time (a double click, or the window and the CLI together, used to save every line
  twice).
- After a crash, Start Recording and Stop in the menu bar and in notifications work from the
  moment Vedivox opens; they used to do nothing, and no meeting was detected, for the minutes Vedivox
  spent finishing the interrupted meeting.
- An import interrupted by a crash or a quit is finished as an import on the next launch: it used
  to be treated as a microphone recording, so every voice in the file became yours, a half-
  extracted file gave a transcript of its beginning only, and a video import ended in "Processing
  Failed".
- An import or a recording started by the command that opened Vedivox (`vedivox import`, `vedivox record
  start`) is no longer mistaken for a meeting a crash interrupted and processed a second time
  alongside the first.
- Reprocess of an import that failed starts again from the imported file. It used to pick up the
  audio a failed extraction had left, transcribe that beginning as the whole meeting, and then
  delete the full file.
- An import that fails while copying the file (a full disk) no longer leaves that copy in the
  data folder with no meeting attached to it.
- Vedivox no longer crashes when the disk fills up: a log line that could not be written took the
  whole app down, in the middle of a recording, and again at every launch until space was freed.
- Merging your own speaker record into another one ("keep the other" in the similar-voices banner,
  or the merge sheet) keeps you marked as the owner; the mark used to vanish with the merged
  record, and with it the link between the microphone and you.
- The call audio of a meeting no longer comes out slowed down, with a garbage transcript, when the
  capture restarted in its first second (an app from the exclusion list starting, the audio device
  settling): the speed check counted across the restart and "corrected" a correct recording.
- A new install no longer rewrites ordinary words in your transcripts and dictation: the term
  vocabulary used to start with a list of live terms («скриншот» → screenshot, «докер» →
  Docker). It now starts as instructions with examples you switch on yourself. An existing
  vocabulary file is not touched.
- Dictation no longer waits for the speaker-recognition model, which it does not use: on a first
  run it hung until that model had downloaded, or failed with "Could not transcribe" when the
  download did.
- A meeting whose call audio could not be transcribed or split into speakers is marked as needing
  attention instead of "done": it used to look finished while holding only your side of the
  conversation, or everyone else unnamed.
- Importing a file with more than two audio channels (a 5.1 video, a multichannel WAV) no longer
  crashes Vedivox.
- Compressing a meeting's audio no longer hangs forever when the disk fills up (the meeting stayed
  "transcribing" and audio compaction stayed "already running" until a restart), and audio that
  could not be read to the end is no longer stored as a shorter recording.
- A meeting no longer ends in "Processing Failed" with its microphone track unplayable because the
  audio could not be compressed at the very end (a full disk): the transcript is kept, the
  uncompressed audio stays the meeting's audio, and the meeting is marked as needing attention.
  Renaming a meeting while it is being processed no longer reverts to the old title when
  processing finishes.
- When Vedivox cannot use its data folder (not writable, or the disk is full at the first launch) it
  says so and names the folder; it used to quit silently, as it does when a second copy is
  started.
- Vedivox no longer crashes on a Shift-click in the transcript's edit mode after the list got shorter
  (a segment was excluded, a search or a speaker filter was applied, another meeting was opened).
- Searching a transcript in edit mode no longer crashes on text with letters whose lowercase form
  has a different length (İ, ẞ and the like).
- Leaving a meeting while it plays (to Speakers, Series or Settings) stops its player completely;
  Vedivox used to keep claiming it was playing, so dictation "paused" Vedivox instead of your music.
- Without access to the microphone a recording no longer "runs" and saves silence in place of your
  voice: Vedivox refuses to start it and says where to allow the microphone. A recording that fails to
  start from the menu bar or from a notification is reported in a notification instead of doing
  nothing.
- Vedivox asks for permission to send notifications when onboarding ends, whether or not meeting
  detection is on. It used to ask only with detection enabled (off by default), so on a default
  install "Text not inserted — on the clipboard", "Recording did not start" and the "not in
  transcript" expiry notice never appeared.
- Calendar access can be granted on a new install: Settings → Recording → Calendar → Allow now
  brings up the macOS permission dialog. The app was missing the description macOS 14 requires for
  it, so the request was refused without a dialog and Vedivox did not even appear under Privacy →
  Calendars.
- Edits stay with the meeting they were made in. Switching meetings within half a second of typing
  in the description lost the last characters, and could write the description into the meeting
  just opened; a speaker change still being applied when another meeting was opened replaced that
  meeting's transcript on screen with the previous one's, and the next rename or Exclude then hit
  the wrong meeting. Typing in the description is also no longer thrown away when something else
  updates the meeting.
- Playback of the meeting you are listening to no longer stops and jumps back to 0:00 whenever
  something else changes: another meeting finishes processing, an import completes, a CLI or MCP
  command runs, the series is changed in the inspector.
- `vedivox-mcp` answers a request that is valid JSON but not a valid request (no method, `"id": null`)
  with "Invalid Request" (-32600) under the request's own id. It used to call it a parse error with
  no id, or not answer at all, so the client kept waiting.
- `vedivox speaker merge` with a speaker id that does not exist exits 2 ("not found") without `--yes`
  too, like `vedivox reprocess` and `vedivox speaker delete`; it used to exit 1 and ask for `--yes`.

