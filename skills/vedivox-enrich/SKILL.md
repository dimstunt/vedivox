---
name: vedivox-enrich
description: Enrich a Vedivox meeting — validate diarization, fix speakers, generate a title and a structured description with timestamps. Supports a single meeting (by ID or context) and batch mode. NOT for querying meeting content (use /vedivox).
allowed-tools: Bash(vedivox:*)
---

# Vedivox Meeting Enrichment

Process a Vedivox meeting to bring it to a fully documented state: correct speakers, meaningful title, structured description with conversation stages and action items.

## CLI

Everything goes through the `vedivox` CLI (skill `vedivox` has the full table).

| Operation | Command |
|-----------|---------|
| Load meeting | `vedivox show <id> --json` (metadata, series, speakers, stored description), `vedivox transcript <id> --json`, `vedivox speakers --meeting <id>` |
| Context search | `vedivox list --from --to --speaker --series`, `vedivox search "<text>"` |
| Fix speakers | `vedivox speaker rename <speaker_id> "<name>"`, `vedivox speaker merge <target_id> <source_id>… --yes`, `vedivox segment set <segment_id> --speaker <speaker_id>` |
| Write enrichment | `vedivox meeting set <id> --title … --description … --series-id …` |
| Series | `vedivox series`, `vedivox series create "<name>"` |
| Batch — list meetings | `vedivox list` with filters |

Action commands run through the app and report its outcome; exit 0 means the change is in.

## Deep Links

```
vedivox://meeting/{meeting_id}           # Open meeting in app
vedivox://meeting/{meeting_id}?t=125.5   # Open at specific timestamp (seconds)
```

Use in description timestamps and when showing segments to user.

## Resolving the Meeting

The user may pass:
- **Meeting ID** (a UUID, any unambiguous prefix works) — `vedivox show <id>` directly
- **Context** (e.g. "the call with Alex yesterday") — `vedivox list --from … --to … --speaker …`, or `vedivox search "<words>" --meetings` to find the right meeting (it also searches titles and descriptions). If ambiguous, ask user to clarify.

Once resolved, load:
1. `vedivox show <id> --json` — metadata, series, speakers, existing description
2. `vedivox transcript <id> --json` — blocks with `speaker`, `from`, `to`, `text`, `segment_ids`
3. `vedivox speakers --meeting <id> --json` — speaker ids and names for this meeting

If the meeting already has a description, show it and ask before overwriting.

## Step 1: Speaker Audit

Check the speaker list for issues:

**Garbage names** — "Speaker 2", "S3", numbered speakers, test names:
- Find their segments in the transcript
- Propose: merge with a known speaker, rename, or delete
- Show deep links to sample segments so user can verify

**Duplicates** — two speakers with similar names or whose segments suggest the same person:
- Propose `vedivox speaker merge <keep_id> <other_id>`

**UNKNOWN segments** — a small number is acceptable and doesn't block enrichment. Only flag if UNKNOWN dominates the transcript.

**Trivial garbage speakers** — if a garbage-named speaker (e.g. `speaker_1`, `S3`) has only 1-2 segments of non-substantive content (goodbyes, "yeah", "uh-huh", filler reactions) that don't affect the meaning or topical flow of the conversation — skip the audit entirely. Don't ask the user, don't propose merges. The cost of fixing exceeds the value. Only flag garbage speakers when their segments carry actual content (opinions, decisions, questions, names being discussed).

**Presenting fixes to user:**
> Speaker "Speaker 3" — 3 segments:
> - [0:42](vedivox://meeting/{id}?t=42) — "we need to talk about…"
> - [1:15](vedivox://meeting/{id}?t=75) — "yes, agreed…"
> - [3:20](vedivox://meeting/{id}?t=200) — "and what about the deadline…"
>
> Suggest: merge into "Alex Morgan" (similar speech context)

After user approves — apply with `vedivox speaker merge … --yes` / `vedivox speaker rename` / `vedivox segment set <segment_id> --speaker <id>` (segment ids come from `vedivox transcript --json`).

If no issues found — proceed silently, no confirmation needed.

## Step 2: Generate Title and Series

**Title format:** `<meeting type> <participants> — <key topics>`, in the language of the meeting.

Examples:
- "1:1 Alex Morgan — hiring plan, Q3 priorities"
- "Team daily — release blockers, flaky tests"
- "Call with Sam Lee — pricing, onboarding feedback"

Infer meeting type from participant count and conversation style (1:1, daily, planning, ad-hoc).

**Series:** if meeting already has a series — leave as is.

Otherwise `vedivox series` lists every series with id and meeting count. Match by name pattern:
- 1:1 with someone → look for "1:1 <Name>" or similar
- Recurring team sync → look for a topical name (e.g. "Team daily", "Design review")
- One-off presentations, ad-hoc → check if a matching series exists

If a match exists — propose `vedivox meeting set <id> --series-id <series_id>`.

If no match but the meeting is clearly recurring — propose `vedivox series create "<name>"` and then assigning.

If the meeting is one-off (ad-hoc, no recurrence) — skip series.

## Step 3: Generate Description

Structure the description as conversation stages with timestamps and action items. Write it in the language of the meeting, headings included.

**Format:**

```markdown
## Stages

### 1. <Stage topic>
[MM:SS](vedivox://meeting/{id}?t={seconds}) — Summary of this stage.
Key decisions, important quotes, context.

### 2. <Next stage>
[MM:SS](vedivox://meeting/{id}?t={seconds}) — ...

## Action items

1. **<Action>** — context, who is responsible, deadline if mentioned.
2. ...
```

**Guidelines:**
- Stages are **topical**, not chronological minute-by-minute. Group related discussion.
- Each stage starts with a timestamp deep link to where this topic begins.
- Keep stage summaries concise — 2-4 sentences, focusing on decisions and key points.
- Skip `<unk>` tokens, overlapping speech artifacts, filler.
- Action items section: only if action items exist. Omit the section entirely if none found.
- Timestamp format: `[MM:SS]` for meetings under 1h, `[H:MM:SS]` for longer.
- Convert timestamps to seconds for deep link `?t=` parameter.

## Step 4: Review and Write

Present the generated title, series suggestion, and description to the user for review.

After approval — write via:
```bash
cat > "$TMPDIR/vedivox-title.txt" <<'VEDIVOX_EOF'
…title…
VEDIVOX_EOF
cat > "$TMPDIR/vedivox-description.md" <<'VEDIVOX_EOF'
…description…
VEDIVOX_EOF
vedivox meeting set <id> --title "$(cat "$TMPDIR/vedivox-title.txt")" \
  --description "$(cat "$TMPDIR/vedivox-description.md")" --series-id <series_id>
```

Pass only the flags that changed. Never type the title or the description inside double quotes on the command line: they carry text from the transcript (quotes, an imported video's title), and a backtick or `$(…)` inside double quotes runs as a command, while a `"` cuts the argument short. The quoted heredoc (`<<'VEDIVOX_EOF'`) takes the text literally.

## Batch Mode

For processing multiple meetings at once. Triggered by date range, "all unenriched", explicit ID list, or natural language ("enrich all meetings from this week").

### Selecting Meetings

`vedivox list --json` with filters:
- Date range: `--from`, `--to`
- Unenriched: `vedivox show <id> --json` per candidate, keep those with an empty `description`
- Explicit IDs: process each
- Any combination the user describes

### Clean Meeting Criteria

A meeting qualifies for automatic enrichment (no user approval needed) if:
- It has no description yet — batch mode never overwrites one without asking
- All speakers are named (no "Speaker 2", "S3", garbage names)
- Small number of UNKNOWN segments — acceptable
- No suspicious speaker duplicates
- Transcript is not empty

### Workflow

1. Get meeting list by filter
2. For each — load metadata + speakers, evaluate clean criteria
3. **Clean meetings** → launch parallel subagents (one per meeting), each runs the full single-mode workflow (Steps 1-4) with auto-approval: generate title/series/description and write via `vedivox meeting set`. Right before writing, each re-reads `vedivox show <id> --json` and skips the meeting if a description appeared meanwhile.
4. **Problematic meetings**, and meetings that already have a description → collect into a markdown review file:

```markdown
# Vedivox Enrich Review — YYYY-MM-DD

## Meeting: <title or ID>
**Date:** ...
**Link:** vedivox://meeting/{id}
**Issues:**
- Speaker "S3" — 15 segments, identity unclear
- Speaker "Speaker 4" — likely duplicate of "Alex Morgan"
- Already has a description — not overwritten
```

5. Report to user: "Enriched N meetings, M need review → `vedivox-enrich-review-YYYY-MM-DD.md`"

Problematic meetings are handled later — user reviews the file, then runs `/vedivox-enrich <ID>` in single mode for each; single mode asks before replacing a description.
