---
name: vedivox-live
description: Use when the user is in a meeting right now and wants help from what is being said, while Vedivox records it — "я на встрече", "я на созвоне", "только что был вопрос", "что он только что спросил", "что сейчас обсуждают", "вытащи контекст со встречи", "помоги ответить", "следи за встречей", "подсказывай по ходу созвона", "I'm in a meeting", "what did they just ask". Reads the live text of the recording in progress. NOT for a meeting that is over (use /vedivox) and NOT for enriching one (use /vedivox-enrich).
allowed-tools: Bash(vedivox:*)
---

# Vedivox Live — help during a meeting

While Vedivox records a meeting it keeps the text of what is being said, both sides of the call.
`vedivox live` reads it. Nothing has to be switched on first: the text accumulates in every
recording. This session already knows the project — the code, the decisions, earlier meetings —
which is what makes its answer worth more than the transcript alone.

## Commands

| Need | Command |
|---|---|
| What was just said | `vedivox live --last 3m` |
| Who said what, with names, right now | `vedivox live --last 5m --precise` (takes a few seconds) |
| The whole meeting so far | `vedivox live > "$TMPDIR/live.txt"`, then `grep` / `tail` it |
| Machine output | `vedivox live [--last 5m] [--precise] --json` — `{"meeting_id", "state", "elapsed", "dropped_seconds", "turns": [{"speaker": {"kind", "name", "confidence"}, "track", "from", "to", "text"}]}` |

The whole text grows by about 2 KB a minute of talk and passes 30 KB after a quarter
of an hour of a lively call; past that, Claude Code hands back only its first 2 KB — the start of the
meeting, not what was just said. So the whole text goes to a file, never straight to the
output. `--last` takes a number with a unit: `90s`, `5m`, `1h`. Times are seconds from the start of the
recording. The MCP tool `get_live_transcript` (`last: "5m"`, `precise: true`) returns the same turns.

## Reading the answer

- **Who said it** comes before every turn. `me` is the microphone. On the call: a **name** is a
  confirmed speaker recognised by voice (`kind: known`, with a `confidence` in `--json`);
  **`Speaker N`** is a voice without a name, the same N for the same voice through the whole
  recording; **`others`** is speech nobody has been told apart in yet.
- **Two layers of text.** Every minute Vedivox re-reads the last three minutes of the recording with
  the pipeline that makes the final transcript: that text is better and carries the speakers.
  What was said since then — up to a minute or so — is quick text, recognised in windows cut at
  pauses, labelled `me` / `others`. `--precise` makes that re-reading happen now (the last
  `--last` minutes, ten at most) and answers when it is done: use it when it matters *who* just
  said something, skip it when you only need *what*.
- **Still preliminary.** Names and `Speaker N` are put by a few minutes of voice and may differ
  from the final transcript; a `Speaker N` may become a name later, for everything that voice
  said. Numbers, names and abbreviations get checked against the source, never quoted from here.
- **A few seconds behind.** A phrase appears after the speaker pauses; someone talking without a
  pause appears up to ~15 s late. If the question the user means is not there yet, read once more
  in five to ten seconds before saying it is missing.
- **`state`** — `ready`; `loading`: the model is not loaded yet, so no text does not mean nobody
  spoke; `unavailable`: there will be no live text in this recording.
- **`dropped_seconds`** above zero — recognition fell behind and skipped that much audio; there
  is a hole in the text.
- **A `me` line that repeats an `others` line** is the call coming out of the speakers into the
  microphone, not the user agreeing.
- Speech marked "not in transcript" (the ⌃⇧⌘1 toggle, muted in Zoom) never appears.
- Exit 1: nothing is being recorded, Vedivox is not running, or live transcript is switched off in
  Settings → Recording. Say so in one line; `vedivox record start` starts a recording if the user
  asks for it. Exit 3 with `access to the Vedivox socket … is denied`: the sandbox — see /vedivox.

## A question was just asked — help me answer

The user is on a call and cannot read much. Be quick and short.

1. `vedivox live --last 3m`. Find the question: usually the last turns that are not `me`. If it
   matters who asked — several people on the call — `vedivox live --last 3m --precise`.
2. Not enough to understand it? `vedivox live --last 10m`, then the whole text through a file.
3. Answer from what this session knows or can look up now — the code, the docs, the decisions,
   an earlier meeting through /vedivox. Check every fact you give against its source.
4. Reply in two to four lines the user can say aloud, then the source in one line (file, doc,
   meeting). If you cannot answer, say what is missing rather than guessing.

## Follow the meeting

For "следи за встречей" / "подсказывай по ходу": read on a timer and speak only when it helps.

1. Every two minutes: `vedivox live --last 150s` (the overlap covers a phrase that was still being
   recognised last time). Use /loop or a scheduled wake-up.
2. Speak only when a question was asked that you can answer in substance, or something said
   contradicts the code or a decision you know. Two or three lines with the source.
3. Otherwise say nothing — a remark every two minutes is noise during a call.
4. `vedivox live` exits 1 → the recording is over: stop the timer. The final transcript appears after
   processing (`vedivox status`, then /vedivox for a summary).
