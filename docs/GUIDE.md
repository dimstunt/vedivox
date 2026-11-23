# Vedivox Guide

The things Vedivox does that a button label won't tell you. Two minutes to read.

## Global hotkeys (work from any app)

- **⌘⇧1** — start / stop a meeting recording, named after the detected meeting like the
  menu bar item. Works while you dictate too. The in-window ⌘⇧R is gone — this key works
  in the window too.
- **⌘⇧2** — start / stop dictation: speak, and the text is typed where your cursor is.
  **Esc** cancels it. Without the Accessibility permission Esc still cancels, but also reaches
  the app you are typing into; the dictation indicator says so once per launch. After you
  allow Vedivox in Accessibility, Esc and the Zoom/Teams mute reading work at once, but pasting
  the text works only after Vedivox is quit and reopened — macOS applies that part on launch.
- **⌃⇧⌘1** — "Not in transcript" while a meeting is recording: what is said while it is on
  stays out of the transcript. Press again to turn it off. If you forget, it turns itself off
  after the limit set in Settings → Transcript (30 min by default, or Never); a new limit
  applies the next time you turn it on.
- **Dictation during a meeting** (⇧⌘2 while recording) stays out of the meeting transcript:
  in its place the transcript shows a "Dictation" plaque with the dictated text. Your words
  are still in the audio; to bring them back, show excluded lines (the eye button) and
  choose Restore to Transcript.
- **Background sound while dictating** (Settings → Dictation → While dictating). *Pause
  playback* (default) pauses the app macOS shows as Now Playing and resumes it when you stop
  speaking — only if Vedivox paused it and it is still the current player. Calls are never
  paused: not Zoom, Teams or Slack, and nothing at all while a meeting is recording. A player
  that does not appear in Now Playing is left alone, and so is a second one: with Spotify and
  Vedivox's own player playing at once, only the one started last is paused. When a recording
  in Vedivox plays to its end, Vedivox steps aside and the next dictation pauses Spotify again.
  *Mute sound* mutes the output device instead; outputs without a mute control (many
  aggregate, virtual and HDMI devices) stay audible, and a mute left behind by a crash is
  undone the next time Vedivox starts.

All shortcuts with modifiers except ⌘⌫ can be changed in **Settings → Shortcuts**; a
combination another Vedivox command already uses is refused with its name, and **Restore
Defaults** brings everything back.

## Recording

- **Start Recording (Multi-Speaker Mic)** in the menu bar icon's menu — for an in-person
  meeting where several people speak into this Mac's microphone: their voices are kept in
  the transcript instead of being hidden as foreign voices. A plain recording does the same
  on its own when the system audio ends up with no speech at all; the menu item is for a room
  with a call going on too. Recording itself is ⌘⇧1 or **Start Recording**.
- **Settings → Recording → Microphone priority** — an ordered list instead of one microphone:
  a recording or dictation opens the first connected entry. **System default** is an entry too,
  and what is below it is never used. Drag rows, or right-click → Move Up / Move Down. A device
  unplugged stays in the list as **Unavailable**. The order is read when the recording starts
  and followed until it stops: the current mic unplugged — the next connected entry takes over
  at once; a higher entry plugged in — the recording moves to it after it has stayed connected
  for 2.5 s (Bluetooth devices flicker while they connect). Every move leaves a short silent
  hole in your track, so keep headphones you only listen through below the mic you speak into.
  Dictation never moves up mid-phrase; it only leaves a mic that is lost. A mic that would not
  start, or started and stayed silent, is skipped for the rest of that recording unless it is
  unplugged and plugged back in.
- **Import:** **⌘I**, or drag an audio file onto the Vedivox window.
- **Quitting during a recording** (⌘Q, log out, restart) stops the recording and saves it
  before Vedivox exits; the transcript is made the next time Vedivox opens. Quitting while a meeting
  is still being processed asks first — processing starts over on the next launch (on log
  out or restart Vedivox quits without asking).
- **Quitting during a dictation** asks first, even while a meeting records (not on log out or
  restart); Quit saves the dictation, then stops the recording. Either way nothing is
  inserted: the audio goes to Dictations as "Not transcribed yet" and is transcribed there the
  next time Vedivox opens, as is a dictation Vedivox was killed in the middle of.
- **Settings → Recording → Not recorded in system audio** — apps whose sound never goes into
  the recording. Add apps that feed your microphone (OBS, Loopback) or play their own
  notification sounds. OBS is there by default. Applies to the next recording.
- **Muted in Zoom** — mic speech while you are muted in the Zoom app stays out of the
  transcript on its own, like the ⌃⇧⌘1 toggle; the call participants stay visible. Vedivox reads
  Zoom's Meeting menu (Mute audio / Unmute audio), so it needs the Accessibility permission
  and Zoom's interface in English; without either nothing is hidden. Bring a line back with
  the eye button → Restore to Transcript. The other way round, mic speech while you are not
  muted is never hidden as a foreign voice — it went into the call. The new Microsoft Teams
  app works the same way, experimentally: Vedivox reads the mic button of the call toolbar
  ("Mute mic" / "Unmute mic", English interface). Not browser calls, not Slack huddles. Off in
  **Settings → Transcript → Hide speech while muted in Zoom or Teams**. If Teams mute is
  misread, run `vedivox mute-debug` during the call, once muted and once not, and send the output.
- **Live transcript** — while a recording runs, `vedivox live` in a terminal prints what has been
  said so far and `vedivox live --last 5m` the last five minutes (a number with `s`, `m` or `h`);
  nothing has to be switched on first. A phrase appears a few seconds after the speaker pauses,
  up to ~15 s for someone who never does, labelled `me` (your microphone) or `others` (the
  call). Every minute Vedivox re-reads the last three minutes with the pipeline that makes the final
  transcript: the text gets better and the call's lines get their speakers — a name for a
  confirmed speaker recognised by voice, `Speaker N` for a voice without one. `vedivox live
  --precise` does that re-reading now and answers a few seconds later. It is all preliminary,
  held in memory until the recording stops and never saved; what you hid with ⌃⇧⌘1 or said while muted in Zoom or Teams is not in it. With headphones off,
  the call also reaches your microphone and shows up twice. The same text is in the window of
  the meeting being recorded: it follows the speaker, stops following once you scroll up to
  read, and resumes when you scroll back to the end. Off in
  **Settings → Recording → Live transcript while recording** (applies from the next recording).
- **Series auto-rule** — a new recording or import joins the series whose rule matches its
  title. To sort meetings recorded earlier, run `vedivox series set <id> --auto-rule <regex>`:
  it applies the rule to every meeting without a series, even when the rule is unchanged.
  `vedivox series apply-rules --yes` runs every series' rule at once (without `--yes` it only counts).
- **Duplicate series** — a calendar event deleted and created again gets a series of its own,
  even with the same name. Merge the two with `vedivox series merge <duplicate> <series to keep> --yes`:
  the meetings move over and the duplicate is deleted. When both were linked to a calendar
  event the kept series keeps its link; the reply says how to switch it to the other one.
- **Series speaker chips** — on the Series page a click on a speaker chip filters the meetings
  to those where the speaker talks; several chips keep only meetings with all of them, a second
  click removes a chip. The number on a chip counts the series' meetings with that speaker.
  Unnamed voices (`Speaker N`) fold into one «N unnamed» chip: it keeps meetings with any of them.
  The Speakers page has the same chips in a «With» row above a speaker's meetings.
- **Settings → Meetings** — its rows and the calendars show once detection is on. The per-app
  toggles and watched calendars apply right away; a call already detected stays detected
  until it goes quiet. Calls are noticed in Zoom, Slack huddles, Microsoft Teams and the Yandex
  Telemost app while they use the mic, and in Google Meet and Telemost browser tabs (Chrome,
  Arc, Safari, Edge, Brave) while the browser plays sound and a meeting room — not the service's
  homepage — is open. One **Yandex Telemost** toggle covers the app and the browser; it is off
  until you switch it on. Telemost mute is not read yet: `vedivox mute-debug` during a Telemost call prints what a reader would need.
  **When a meeting starts** — a notification (default) or start recording on its own; a
  recording you stopped by hand blocks the auto start for 10 minutes, so a call that drops
  out and comes back does not restart it. **When a meeting ends** — a reminder to stop
  (default) or stop on its own. Start and stop are separate because one call often runs into
  the next. The meeting counts as ended once the call has not used the mic for **Meeting
  counts as ended after** (15 s); the reminder then repeats every **Reminder interval** (1 min)
  until the call comes back or the recording stops, and waits while your mic hears speech.
  The auto stop warns first and stops one reminder interval later, again not while your mic
  hears speech — a room change or a reconnect does not cut the recording. While Vedivox waits after
  the call, the menu bar icon blinks (steady with Reduce Motion) and, with the auto stop on, shows
  the seconds left. To go on without the call, choose **Keep Recording** — the reminder's button
  or the first item of the menu bar menu: no more reminders and no auto stop until the next call is
  detected and ends.

## Navigating

- **⌘K** — Quick Search: type part of a meeting title, a line from its transcript, a speaker
  (any spelling of the name), a series, a screen or a menu command; **Return** opens it.
- **⌘[ / ⌘]** — back / forward between the screens you visited, like a browser.
  Back/forward and returning from the sidebar restore where you left a screen — the
  meeting player's position (paused), the selected speaker, the settings section;
  forgotten on quit.
- **⌘,** — Settings, in the main window. With the window closed, ⌘, or **Open Vedivox** in the
  menu bar icon's menu brings it back.
- **⌘F** — search in the open section (meetings, speakers, series). **Esc** leaves search;
  in the meeting list and the transcript search the first **Esc** clears the query.
  A meeting matches when every word of the query occurs somewhere in it: any line, the title
  or the description.
  `vedivox search` is narrower on purpose: it returns transcript lines, so every word must occur
  in one line, and titles and descriptions are not searched. `vedivox search --meetings` searches
  the way this list does and prints the meetings found.
- **⌥⌘I** — show / hide the inspector (description, series).
- **⇧⌘J** — Reveal in Sidebar: scrolls the meeting list to the open meeting, clearing a
  search or speaker filter that hides it. The round crosshair button in the bottom-right corner of
  the meeting list does the same.
- **⌘-click / ⇧-click** in the meeting list selects several meetings; **⌘⌫** deletes the
  selection. In a text field with text before the cursor ⌘⌫ deletes that text instead.
- **⇧⌘E** — export the selected meeting to Markdown.

## Player

Only when the cursor is not in a text field:

- **Space** — play / pause. **← / →** — seek (step in Settings → Shortcuts).
- **⌥[ / ⌥]** — slower / faster, changed in Settings → Shortcuts like any other shortcut. In a
  text field they type as usual.
- **Mix / Mic / Sys** above the transcript — listen to both tracks, only your microphone, or
  only the other side.

## Transcript

- **All / Mic / System** in the transcript header picks whose lines are shown; it is separate from
  the player's Mix / Mic / Sys, which picks what you hear. On **Mic**, **Exclude mic track** hides
  the whole microphone track at once (one mark from start to end, the system track untouched) and
  **Restore mic track** brings it back — lines you hid by hand before stay hidden.
- **Click a phrase** — playback jumps to it.
- **⌘-click a phrase** — copies its text (no timecode); playback stays put. Single words
  cannot be selected with the mouse — the phrase is one link; Copy Text in the right-click
  menu copies the whole turn with timecodes.
- **Right-click a timecode** — Copy Timecode, Copy Link to Moment (a `vedivox://` link that opens
  this meeting at this second), Copy Text, Jump Here.
- **Edit speakers** (the pencil next to "Speaker:") — ⌘-click / ⇧-click segments to select several,
  then reassign the speaker, mark as you, or exclude them in the bar that appears.
- **Double-click the description** in the inspector to edit it.
- **Speakers screen:** ⌘-click selects several speakers. Right-click → **Delete Speaker…** removes a
  speaker: their lines become unnamed and the voice is no longer recognised (CLI:
  `vedivox speaker delete <id> --yes`, which has no undo).
- **⌘Z after a speaker merge, rename or delete** — Edit → Undo puts back the last merge, profile
  rename, Delete Speaker, Rename Speaker or Mark as Me, while the meeting has not been reprocessed
  since. It is also refused once the same speakers or lines were changed some other way: a speaker
  deleted or marked as you, a line reassigned by hand.
- **Split sheet:** the cut opens at the start of the segment being played; ← → move it by a
  second, ⌥← ⌥→ to the previous or next segment start.
- **Trim sheet:** ← → move the chosen bound by a second, ⌥← ⌥→ to the previous or next
  segment (start to segment starts, end to segment ends); **Tab** switches between Start and End.
- **Undo Trim / Undo Split / Undo Merge** stay available for 7 days. After that the saved
  copy of the original audio is deleted on launch, and the undo goes with it.
  Only the last edit of each kind can be undone, and a split drops the undo of an earlier trim
  (a trim already dropped the undo of a split).
- **From the command line:** `vedivox meeting split <id> --at <s> [--at <s>…]`,
  `vedivox meeting trim <id> [--from <s>] [--to <s>]`, `vedivox meeting merge <id> <id> […]` and
  `vedivox meeting undo split|trim|merge <id>` do what the buttons do; times are seconds from the start
  of the recording, as in `vedivox transcript --json`. Without `--yes` they only say what would change.
  Several cut points cut from the last back; several meetings join in order of start into the earliest.
  `undo split` takes either part.

## Listen

Unnamed voices that sound like a known person, and unnamed voices that sound like no one you
know but speak in three or more meetings ("Unnamed voice in N meetings": its fragments come one
from each meeting, and a decision applies to all of them). Keys work when the cursor is not in a
text field:

- **Space** — play / pause the fragment (the first 15 s of the voice's longest stretch).
  **← / →** or the arrows beside "fragment 1 / 14" — previous / next fragment, longest first.
  **↑ / ↓** — previous / next voice.
- **1 / 2 / 3** — this is candidate 1, 2 or 3. **⌥1 / ⌥2 / ⌥3** — hear that candidate's own
  voice (their longest line in their latest other meeting).
- **N** — a new person: type the name, **Return** applies, **Esc** cancels. An existing name
  lands on that person. **/** — pick another known speaker by name.
- **S** — skip: listened, no name. Skipped voices stay out of the list, also after Reprocess;
  the **Skipped** checkbox shows them.
- **O** — open the meeting at the fragment.

Every way of moving lines to a speaker records a verdict on that stretch of audio, so Reprocess
keeps your fixes. Before reprocessing a meeting fixed some other way, pin its speakers:
`vedivox meeting pin-speakers <id> --yes`. To drop one verdict, find it in `vedivox marks <id>` and
run `vedivox unmark <id> --id <mark-id>`; the lines stay where they are until the next Reprocess.

## Vocabulary

Speech recognition spells technical terms and names phonetically. Fix them in the
vocabulary file — **Settings → Transcript → Vocabulary → Open** — one term per line:

```
GitHub: гитхаб, гитхап
Docker: докер, докеру, докере
```

Edits apply to the next processing and the next dictation, no restart needed; for an older
meeting use Reprocess.

## Disk space

New recordings are stored at 64 kbps, 24 kHz. Older ones (128 kbps) can be re-encoded to
the same format to free about 40 % of their space:

```
vedivox audio compact --dry-run   # how many tracks, how much space — changes nothing
vedivox audio compact             # does it; Vedivox must be running
```

This is lossy and cannot be undone: copy `~/Library/Application Support/Vedivox/audio` to an
external disk first if you want a way back. Saved transcripts do not change, but
processing a re-encoded meeting again recognises a little less (about 2–3 points more
word errors on the call track in our measurements). Each copy is checked against the
original before it replaces it; a recording that starts mid-run stops it, and running the
command again continues where it left off.

**Settings → Storage** shows what takes the space: the database, the meeting audio, the speech
models (about 1.2 GB, more once you change the dictation chunk size, in `~/Library/Application Support/FluidAudio/Models`, outside Vedivox's own
folder, so deleting Vedivox leaves them; deleted, they are downloaded again when needed) and the
automatic database backups made before an update.

## Updates

- Once a day (and at launch, if a day has passed) Vedivox asks GitHub for its latest release —
  one anonymous request, nothing about you or your meetings goes with it. When a newer
  version is out, **Vedivox → Vedivox X.Y.Z Is Available…** appears (also in the Help menu and in
  Settings → About): the release notes, the release page and a
  `brew upgrade` command to copy. Nothing is downloaded or installed by itself.
- Turn it off in **Settings → About → Check for updates**; **Check Now** asks once
  regardless.

## When something goes wrong

- Logs: **Settings → Storage → Logs → Open Folder**. More detail:
  **Settings → Storage → Debug logging**.
- Something that needs a macOS permission does nothing (no system audio, dictation not typed,
  no notifications): **Settings → Privacy & Permissions** lists each permission Vedivox uses, with
  Open Settings. System audio and Automation are not reported by macOS. **Check** next to System
  audio asks macOS and listens for a second — play any sound first, or it can only say it heard
  silence; a recording that hears the other side confirms it too. A recording without system
  audio shows a banner, and so does one where a call app plays but the system track stays silent
  for a minute: then turn Vedivox on in System Settings → Privacy & Security → Screen & System
  Audio Recording and start the recording again.
- "Call audio is coming through chopped" during a recording: the other side reaches the recording
  in short pieces, and restarting the capture (Vedivox tries three times on its own) did not fix
  it. In the call app, switch the speaker to another device and back; the banner goes away about a
  minute after the sound is whole again. The meeting keeps a "!" because part of the call is lost.
- "Updating your library…" on the first launch after an update: Vedivox copies the database into
  `~/Library/Application Support/Vedivox/backups/` (the newest three are kept), then applies the new
  version's changes. A large library takes a minute or two; meetings reappear when it is done.
- Speech played faster than it was spoken — a video at 2× — comes out as scraps of text, some
  of them in English: the recognition model cannot follow it. Live text and the final
  transcript read the same sound and fail alike; record at normal speed.
- Reprocess keeps the current transcript on screen until the new one replaces it; the sidebar
  shows the meeting as processing. If the run fails, the transcript you had stays.
- Command line: `vedivox status`, `vedivox list`, `vedivox transcript <id>` — see `vedivox --help`.
- `vedivox feedback` packs a zip for whoever gave you Vedivox onto the Desktop: logs (with meeting
  titles and speaker names), notes and versions — no database, no audio.

---

Vedivox is free and open source. If it helps you, a star on GitHub (Help → Star Vedivox on GitHub)
helps others find it.
