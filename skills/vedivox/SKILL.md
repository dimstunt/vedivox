---
name: vedivox
description: Use when user asks about meetings — summaries, what was discussed, what someone said, searching across meetings by topic, listing meetings for a period — or wants meeting data changed from the command line (import a recording, reprocess, rename or merge speakers, exclude an interval, set a title or series). Triggers — "о чём была встреча", "что обсуждали", "что сказал X", "найди встречу про", "какие встречи были на неделе", "импортируй запись", "переобработай встречу", "переименуй спикера". NOT for enriching meetings (use /vedivox-enrich) and NOT for help during a meeting in progress (use /vedivox-live).
allowed-tools: Bash(vedivox:*)
---

# Vedivox Meeting Assistant

Vedivox (meeting recorder) is driven through the `vedivox` CLI — same database and socket the app uses.
No MCP: the CLI costs nothing until called and works from subagents. `vedivox --help`, `vedivox <cmd> --help`.

## Reads — straight from the database, the app may be closed

| Need | Command |
|---|---|
| Meetings for a period / by speaker / by series | `vedivox list --from 2026-09-01 --to 2026-09-07 --speaker Alice --series 121 --limit 50 --json` (done only by default; `--status recording` to widen) |
| One meeting in full: date, duration, speakers, series, stored description | `vedivox show <id> [--json]` |
| Transcript with speaker labels and timestamps | `vedivox transcript <id> [--from <sec>] [--to <sec>] [--json]` — JSON blocks carry `segment_ids` |
| Full-text search across all meetings | `vedivox search "<query>" [--limit 50] [--json]` — returns lines with every word (as a prefix) in one line; titles and descriptions are not searched, so search for words said together |
| Meetings that contain the words anywhere — lines, title, description (the sidebar's search) | `vedivox search "<query>" --meetings [--limit 50] [--json]` — prints the meeting list of `vedivox list`, newest first |
| Known speakers (all, or of one meeting) | `vedivox speakers [--meeting <id>] [--json]` |
| Series | `vedivox series [--json]` |
| Marks of a meeting: exclusions and speaker verdicts (`speaker` rows carry `speaker_id` and the name) | `vedivox marks <id> [--json]` |
| Voices to check by ear: unnamed voices that sound like a known person, most speech first | `vedivox queue [--meeting <id>] [--limit N] [--skipped] [--json]` — computed by the app; item id is `meetingPrefix:speakerPrefix` |
| What is recording / processing now, or one meeting's state | `vedivox status [<id>] [--json]` — `status` (`done`, …) and `stalled` |
| What is being said in the meeting recorded right now | `vedivox live [--last 5m] [--precise] [--json]` — preliminary text from the running app, each turn after who said it (`me`, a recognised speaker's name, `Speaker N`, `others`); `--precise` refines the last minutes first; exit 1 when nothing is recording. Workflows: /vedivox-live |

## Actions — go through the running app; the exit code is the app's outcome

| Need | Command |
|---|---|
| Import a file or YouTube URL as a meeting | `vedivox import <path\|url> [--title …] [--date YYYY-MM-DD]` |
| Transcribe a one-off file or YouTube URL (voice message, lecture) without saving anything — no meeting, no speaker rows, voice profiles untouched; known speakers still recognized | `vedivox transcribe <path\|url> [--json]` |
| Re-transcribe and re-diarize | `vedivox reprocess <id> --yes [--suppress-echo]` (without `--yes` it only names the meeting, exit 1) — also applies a changed vocabulary to an old meeting |
| Speakers: rename / merge / detach from meetings | `vedivox speaker rename <speaker-id> <name>` · `vedivox speaker merge <target-id> <source-id…> --yes` · `vedivox speaker detach <speaker-id> <meeting…>` · `vedivox speaker delete <speaker-id> --yes` (lines go unnamed, the voice is forgotten) |
| Title, description, series | `vedivox meeting set <id> [--title …] [--description …] [--series-id <id>]` (empty string unlinks) |
| Cut a meeting into parts / keep only a stretch / join meetings | `vedivox meeting split <id> --at <s> [--at <s>…] [--yes] [--json]` (the meeting stays part 1, new parts are titled "… (2)"; several points cut from the last back, all in seconds of the original) · `vedivox meeting trim <id> [--from <s>] [--to <s>] [--yes] [--json]` · `vedivox meeting merge <id> <id> [<id>…] [--yes] [--json]` (into the earliest, in order of start). Without `--yes` they print the plan and exit 1. Workflow below — never cut without the user's yes |
| Undo the last split / trim / merge | `vedivox meeting undo split\|trim\|merge <id> [--yes] [--json]` — `split` takes either part; `trim` reprocesses the meeting (text and speaker edits are lost) and waits; only the last edit of a chain can be undone |
| Delete meetings (audio to the Trash, transcript out of the DB) | `vedivox meeting delete <id…> --yes [--json]` — without `--yes` only lists what would go (exit 1); all ids resolve first, so one unknown/ambiguous id deletes nothing; a meeting still recording or processing is refused (exit 1). Confirm with the user before running |
| Exclude an interval from the transcript (reversible) | `vedivox mark <id> --from <sec> --to <sec> [--track mic\|system\|merged\|import]`; undo with `vedivox unmark <id> --id <mark-id>` |
| Reassign a segment to a speaker | `vedivox segment set <segment-id> --speaker <speaker-id>` (ids from `transcript --json` and `speakers --json`). Writes a verdict, so the move survives `vedivox reprocess`, and recalculates both voices |
| Reassign every line of a time range | `vedivox segment set <meeting> --from <sec> --to <sec> [--track system\|mic\|…] --speaker <speaker-id>` — lines covered ≥ 50 % move, the verdict lies exactly on the range |
| Decide a queue item | `vedivox queue assign <item> --speaker <speaker-id>` · `vedivox queue assign <item> --new "<name>"` (an existing name lands on that record) · `vedivox queue skip <item>` (listened, no name; stays out of the queue after reprocess). Exit 2: the voice is gone (reprocessed or decided) — re-list |
| Keep hand-fixed attribution across a reprocess | `vedivox meeting pin-speakers <id…> --yes [--json]` — pins every confirmed speaker's current lines as verdicts; without `--yes` only lists speaker — seconds (exit 1). Remove one verdict with `vedivox unmark <id> --id <mark-id>` |
| Series: create / rename, link calendar, title auto-rule / merge duplicates / delete | `vedivox series create <name>` · `vedivox series set <id> [--name …] [--calendar-series-id …] [--auto-rule <regex>]` (the rule joins matching series-less meetings at once, also when re-sent unchanged; empty string clears) · `vedivox series merge <duplicate> <keep> [--yes]` (the duplicate's meetings move to `<keep>`, then it is deleted; `<keep>` keeps its name, calendar link and rule; without `--yes` only says what would move, exit 1) · `vedivox series delete <id> --yes` (meetings stay, lose the link) · `vedivox series apply-rules [--yes]` (every rule over all series-less meetings, first match wins; without `--yes` only counts, exit 1). `create` with an existing name (case ignored) returns that series instead of a duplicate; calendar series may still share a name: a recreated calendar event gets its own series by design — find such pairs in `vedivox series` (same name, both with meetings) and merge them into the older one |
| Start / stop a recording in the app | `vedivox record start [--title …] [--json]` (no title: taken from the detected meeting, as the menu does; `--json` gives `meeting_id`, `system_audio` — `false` means mic only) · `vedivox record stop [--json]` (does not wait for processing, see `vedivox status`). Exit 1: already recording / nothing to stop |
| Shrink the stored archive | `vedivox audio compact --dry-run [--json]` first — counts tracks and the space to free, changes nothing; then `vedivox audio compact`. **Lossy and irreversible**: re-encodes older 128 kbps tracks to 64 kbps @ 24 kHz in place. Run only when the user asked, never on your own. Needs Vedivox running (exit 3 otherwise, it never launches it); exit 1 when some tracks failed (originals kept) or a recording started mid-run — run again to continue |
| Diagnose a misread mute state in a call | `vedivox mute-debug` — prints what the Zoom and Teams mute readers see now, the Teams accessibility tree around the mic button and the Yandex Telemost trees; run it during the call, once muted and once unmuted. Never launches the app |

## Conventions

- Meetings are addressed by UUID or any unambiguous prefix; an ambiguous prefix is refused (exit 1) with the candidates.
- `--json` is the stable contract: snake_case keys, array for lists, object for one result. Data on stdout, diagnostics on stderr.
- Exit codes: 0 done, 1 refused, 2 not found, 3 data/app unavailable, 64 usage. Zero on an action means the app did it, not that the request was delivered.
- Waiting for processing: `while :; do s=$(vedivox status <id> --json | jq -r 'if .stalled then "stalled" else .status end'); case "$s" in recording|transcribing|diarizing) sleep 10 ;; *) break ;; esac; done; echo "$s"`. Processing ends in `done`, `error` or `needsAttention` — never wait for `done` alone; why it did not end in `done` is `status_reason` in `vedivox show <id> --json` (comma-separated codes such as `system`, `mic compression`; absent for meetings processed before 2026-11). `stalled` means the app is not running and nothing will change; an empty result means `vedivox status` failed (exit 3: the database is unavailable).
- Actions and `vedivox status` reach the app through the socket `~/Library/Application Support/Vedivox/command.sock`. Inside the Claude Code sandbox it must be listed in `sandbox.network.allowUnixSockets`; otherwise they fail with exit 3 and `access to the Vedivox socket … is denied` — the app may be running fine, do not relaunch it. `could not launch Vedivox: … Launch Services refused` means the sandbox blocked starting the app: ask the user to open Vedivox, then retry. YouTube downloads go to `$TMPDIR` and are removed after the app answers.
- Transliterated terms and names come out wrong («дашборд», «гитхаб»)? Add them to `~/Library/Application Support/Vedivox/vocabulary/terms.txt` (`canonical: alias1, alias2`, the file's header explains the thresholds); next transcription picks it up, `vedivox reprocess <id> --yes` for an old one.

## Workflows

### Meeting Summary

1. `vedivox show <id>` — title, speakers, duration, whether a description already exists
2. `vedivox transcript <id>` — read the whole thing
3. Summarize by topics discussed, not chronologically
4. List decisions made and open questions
5. Note action items with who was assigned

**Tip:** Transcripts have overlapping speech and recognition artifacts (`<unk>`, garbled text). Focus on meaning, skip noise.

### What Did Someone Say?

1. `vedivox transcript <id> --json` — blocks carry `speaker`, `from`, `to`, `text`
2. Filter blocks by speaker name
3. Summarize their key points and positions

**Speaker labels:** speakers' names (the user's too, unmarked), or `speaker_2`/`Unknown` for unidentified participants. Which name is the user's: ` (me)` in `vedivox speakers` (`is_me` in `--json`), ` (★)` in the speaker list of `vedivox show` and `vedivox list`. Use context to infer identity when possible.

### Search Across Meetings

1. `vedivox search "<keyword>"` — hits carry meeting id, title, timestamp and the matching text
2. `vedivox show <id>` on relevant hits for context (date, speakers)
3. Synthesize findings across meetings

**Empty answer is not "never discussed".** The line search wants every word in one line; split
the query and try again before going to Slack or other sources:

- `vedivox search "<query>" --meetings` — the words may sit in different lines, the title or the
  description; then `vedivox transcript <id>` or a one-word `vedivox search` to reach the lines.
- one word at a time, the most specific first;
- other word forms: words match as prefixes, so cut the ending (`бюджет` finds `бюджета`,
  `бюджетом`), and try the spoken form (see "Search the sound" below).

**Looking for a meeting by its name** ("встреча про онбординг", "последний 1:1 с Ниной"): it is
in the title, which the line search never sees — use `vedivox search "<words>" --meetings`, or
`vedivox list --series <name>` / `vedivox list --from … --to …` and read the titles.

**Use for:** "когда мы обсуждали X?", "что решили по поводу Y?"

### Cut a long recording into calls, or join a call recorded in parts

1. `vedivox transcript <id> --json` — find the boundaries: a long pause, a goodbye and a new greeting,
   a change of people and topic. `from` of the first line of the next call is the cut point.
2. Show the user every point with a quote on each side ("…до встречи" | "Привет, начнём с…") and the
   plan from `vedivox meeting split <id> --at <s> …` without `--yes` (parts, lengths, line counts).
3. Only after the user's yes: the same command with `--yes --json` — it returns the ids in time order.
4. Give each part a title: `vedivox meeting set <id> --title "…"` (new parts are called "… (2)").

For a call recorded in parts: check the pieces follow each other (`vedivox list`, start times and
lengths), show them to the user, then `vedivox meeting merge <id> <id> … --yes`. Merge does not
reprocess and does not re-match unnamed voices across the two parts: check `Speaker N` labels in the
merged transcript before naming them.

A wrong cut: `vedivox meeting undo split <id of either part> --yes` (only the last cut of a chain).

### List Meetings for Period

1. `vedivox list --from … --to …` (done meetings by default; `--status` to widen)
2. Group as needed; `vedivox show <id>` for the ones that matter

### Naming voices by ear

Never move a voice line by line. One decision is one command:

```bash
vedivox queue --json | jq '.[0]'                       # the biggest unnamed voice, its fragment and candidates
vedivox queue assign 3f2a91c0:8b1d --speaker <id>      # every line of that voice → the speaker
```

When the user has listened and marked ranges by hand (anchors like «12:04–19:30 is Alice»),
one range is one call, not hundreds of `segment set`:

```bash
vedivox segment set 3f2a91c0 --from 724 --to 1170 --track system --speaker <speaker-id>
```

Before reprocessing a meeting whose speakers were fixed by hand, pin them first —
otherwise the new pass forgets the fixes:

```bash
vedivox meeting pin-speakers 3f2a91c0                  # lists who and how many seconds (exit 1)
vedivox meeting pin-speakers 3f2a91c0 --yes
vedivox reprocess 3f2a91c0 --yes
```

The log line `Verdicts: …` after processing reports how many lines the verdicts moved and how
many of those the pipeline had given to another confirmed speaker.

### Search the sound, not the spelling

Full-text search runs over ASR output.

- **Numbers and jargon are spoken, not written.** A whole discussion of selection thresholds was
  invisible to a search for «порог», because on the call people said «п85» and «топ-15%».
  `0.598` and `energy_limitation_severity` appear in no transcript; `mild` does. Try the spoken
  form, the transliteration and a plain-language paraphrase before concluding a topic is absent.
- **Identifiers, versions and ticket IDs are mangled beyond recognition** — do not search for them.
- **People are referred to by first name only.** Where several colleagues share one (three people
  called «Ирма»), a title is not evidence: check the speaker list from `vedivox show`.

## Deep Links

```
vedivox://meeting/{meeting_id}           # Open meeting in app
vedivox://meeting/{meeting_id}?t=125.5   # Open at specific timestamp
```

Use when referencing specific moments in responses — user can click to listen.

## Transcript Quality Notes

- Overlapping speech creates interleaved blocks with close timestamps
- `<unk>` tokens = unrecognized words, skip them
- Speaker diarization isn't perfect — same person may appear as different speakers
- The user (device owner): ` (★)` in the speaker lists of `vedivox show` and `vedivox list`, ` (me)` in `vedivox speakers` (`is_me` in `--json`); transcript lines carry no mark

## Feedback

When the user complains about Vedivox or a `vedivox` command misbehaves, write a note to
`~/.claude/vedivox/feedback/<YYYY-MM-DD>-<topic>.md`:

```
What I did: …
Expected: …
Got: …
Meeting id: … (if any)
Vedivox version (build): … (`/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" -c "Print CFBundleVersion" /Applications/Vedivox.app/Contents/Info.plist`)
Log excerpt: the vedivox.log lines around the event (~/Library/Application Support/Vedivox/logs/vedivox.log)
```

Then tell the user the archive will include the log, which holds meeting titles, speaker
names and file paths, and ask before packing it. On a yes, run `vedivox feedback` yourself; if
it cannot write to the Desktop (exit 3, sandbox), rerun with `--output <writable dir>`. Give
the user the archive path and ask them to send it to whoever gave them Vedivox.

## Related Skills

- `/vedivox-enrich` — enrich a meeting: fix speakers, generate title + description, optionally create tasks
