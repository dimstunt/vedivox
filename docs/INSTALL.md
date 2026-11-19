# Installing Vedivox

These instructions are written for the recipient's Claude Code: run the steps
yourself, and where a step is marked **[human]**, tell the user where to click.
The app is signed with a Developer ID and notarized by Apple, so macOS opens it
like any other app downloaded from the Internet.

## What is in the archive

- `Vedivox.app` — the app: meeting recording, transcription and speaker
  diarization, all on the Mac (nothing goes to the cloud).
- `vedivox` — a CLI over the same database (step 5).
- `vedivox-mcp` — an MCP server (stdio) over the same data, for MCP clients other than
  Claude Code; optional. README.md lists what it can do.
- `skills/vedivox` — a Claude Code skill: CLI commands, exit codes and meeting
  workflows (step 5).
- `skills/vedivox-live` — a second skill: help during a meeting from its live text.
- `skills/vedivox-enrich` — a third skill: checks a meeting's speakers and writes its title and a
  description with timestamped stages (`/vedivox-enrich <meeting id>`).
- `install.sh` — installs all of the above with one command (step 1).
- `cli_alias.sh` — used by `install.sh`: adds the short names `vox` and `vox-mcp` as links to
  `vedivox` and `vedivox-mcp`, where those names are free.
- `GUIDE.md` — the non-obvious parts of the UI: hotkeys, modifier clicks,
  settings files. Also in the app: Help → Vedivox Guide.
- `CHANGELOG.md` — what changed in each version. Also in the app:
  Help → What’s New.
- `INSTALL.md` — this file.
- `LICENSE` — the GNU General Public License, version 3; Vedivox is GPL-3.0-or-later.
- `THIRD_PARTY_NOTICES.md` — the licences and notices of the libraries and data built into
  Vedivox, in full.

## Requirements

- macOS 14.4+ on Apple Silicon (the models run on the Neural Engine).
- Internet on first launch: the app downloads its ML models by itself
  (about 1.2 GB, once).
- ~3 GB of free disk (models + compilation caches). When the disk is nearly
  full, macOS evicts the compiled-model cache and every launch waits ~30 s for
  recompilation — keep some headroom.

## 1. One-command install

From the unpacked archive folder:

```bash
bash install.sh
```

The script removes the quarantine flag and installs `Vedivox.app` into
`/Applications`, `vedivox` and `vedivox-mcp` into `~/.local/bin`, the skills into
`~/.claude/skills/vedivox`, `~/.claude/skills/vedivox-live` and `~/.claude/skills/vedivox-enrich`, then
opens Vedivox. Updating to a new version is the same command from the new archive: everything installed
is replaced (including any local edits in those skill folders). If Vedivox is running at that moment, the
script leaves it alone — **[human]** restart the app when nothing is recording.

If the script printed that `~/.local/bin` is not in `PATH`, run the line it
showed and open a new terminal.

Check: `codesign -v --deep /Applications/Vedivox.app` exits silently (code 0).
The signature is "Developer ID Application" (`codesign -dvv /Applications/Vedivox.app`
shows it on the `Authority=` lines).

### Manual install (fallback)

If the script failed (the `xattr` line is what `install.sh` does too; a notarized app
opens without it):

```bash
xattr -dr com.apple.quarantine Vedivox.app
rm -rf /Applications/Vedivox.app
ditto Vedivox.app /Applications/Vedivox.app
```

CLI and skill — step 5.

## Installed with Homebrew

`brew install --cask dimstunt/tap/vedivox` installs `Vedivox.app` and links `vedivox` and
`vedivox-mcp` into Homebrew's `bin`, so skip step 1 and the manual CLI install in step 5.
The cask does not install the Claude Code skills; add them as a plugin, in Claude Code (the
cask prints these two commands after installing; `brew info --cask vedivox` shows them again):

```
/plugin marketplace add dimstunt/vedivox
/plugin install vedivox@vedivox
```

The skills are then `/vedivox:vedivox`, `/vedivox:vedivox-live` and `/vedivox:vedivox-enrich`;
after an upgrade `/plugin marketplace update vedivox` brings the newer ones.

## 2. First launch

```bash
open /Applications/Vedivox.app
```

`install.sh` opens the app itself. If macOS still refuses to open it, the
quarantine flag is the usual cause: `xattr -dr com.apple.quarantine /Applications/Vedivox.app`
and open again.

## 3. First launch: models

A **Loading transcription model…** banner appears at the top: the models are
being downloaded and compiled for the Neural Engine. The first time takes
minutes; do not quit the app on this banner. After that, launch takes seconds.

## 4. Permissions (TCC)

The dialogs appear as features are used; nothing needs enabling upfront.

- **Microphone** — on the first recording (**[human]**: Allow in the dialog).
- **System audio recording** — to hear the other side of Zoom/Meet calls:
  **[human]** System Settings → Privacy & Security → Screen & System Audio
  Recording → enable Vedivox (macOS asks to restart the app).
- **Calendar** (optional, to link meetings to events): **[human]** Allow in
  the dialog.
- **Automation / Apple Events** (optional): Allow in the dialog.

Check after granting: start a 15–20 second test recording, say something,
stop — the transcript appears in the meeting details (stage banner:
Transcribing… → Identifying speakers…).

## 5. CLI and skill

`install.sh` has already installed both; below is the manual path.

```bash
mkdir -p ~/.local/bin
cp vedivox ~/.local/bin/vedivox
codesign -s - --force ~/.local/bin/vedivox
# if ~/.local/bin is not in PATH:
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
```

Quick check: `vedivox status` → a line `app: running` (or `app: not running`
when the app is closed — also a valid answer).

The basics: `vedivox list`, `vedivox status [id]`, `vedivox transcript <id>`,
`vedivox search <query>`, `vedivox speakers`, `vedivox import <file>`,
`vedivox reprocess <id> --yes`. The reading commands take `--json` (`vedivox <command> --help`
says which others do); meetings are addressed by
UUID or an unambiguous prefix of it. Exit codes: 0 done, 1 refused,
2 not found, 3 data/app unavailable, 64 bad arguments.

The Claude Code skill, so Claude knows the commands and workflows ("what was
the meeting about", "what did X say", "import this recording"):

```bash
mkdir -p ~/.claude/skills
cp -R skills/vedivox skills/vedivox-live skills/vedivox-enrich ~/.claude/skills/
```

They show up as `/vedivox`, `/vedivox-live` and `/vedivox-enrich` in the next Claude Code session.
The same skills also come as a plugin that Claude Code keeps up to date — `/plugin marketplace
add dimstunt/vedivox`, then `/plugin install vedivox@vedivox`; use one way or the other.

There is also an MCP server, `vedivox-mcp`: it is in the archive and `install.sh` puts it in
`~/.local/bin`. The CLI is enough for Claude Code; MCP is optional.

## 6. Term vocabulary (optional)

Speech recognition transliterates technical terms and names ("дашборд",
"гитхаб", "докер"). The file
`~/Library/Application Support/Vedivox/vocabulary/terms.txt` fixes them after
recognition — in meeting transcripts and in dictation. It is created on first
launch with instructions in its header; one term per line:

```
GitHub: гитхаб, гитхап
Docker: докер, докеру, докере
```

- Word forms need not be listed — matching is fuzzy (threshold 0.80). The
  exception is words of 6 letters or fewer: their threshold is 0.92, so list
  the forms explicitly (see Docker).
- Do not add short frequent words ("прод", "баг", "релиз") — an alias that
  looks like an ordinary word rewrites normal speech.
- Applies to the next processing and the next dictation without a restart;
  for an older meeting run `vedivox reprocess <id> --yes`. In the app: Settings →
  Transcript → Vocabulary → Open.

## 7. Where things live

- Database: `~/Library/Application Support/Vedivox/Vedivox.sqlite`
- Meeting audio: `~/Library/Application Support/Vedivox/audio/<meetingId>/`
- Log: `~/Library/Application Support/Vedivox/logs/vedivox.log` — look here first
  when something goes wrong.
- Speech models (about 1.2 GB, downloaded on first launch):
  `~/Library/Application Support/FluidAudio/Models` — outside the Vedivox folder;
  delete it by hand when you remove Vedivox.

## Troubleshooting

- "Vedivox is damaged and can’t be opened" — the quarantine flag was not removed:
  repeat `xattr -dr com.apple.quarantine /Applications/Vedivox.app`.
- The model banner stays for more than ~5 minutes — check the internet
  connection and free disk (see Requirements), then restart the app.
- The other side is silent in recordings — the Screen & System Audio Recording
  permission is missing (step 4).

## Sending feedback

```bash
vedivox feedback
```

Puts `vedivox-feedback-<date-time>.zip` on the Desktop (`--output <folder>` for another place)
and prints its path. Inside: your notes from `~/.claude/vedivox/feedback` (Claude writes them
there when you tell it something went wrong), the Vedivox logs and a `system.txt` with the Vedivox
and macOS versions. Never the database or the meeting audio.

The logs do contain meeting titles, speaker names and paths of imported files — look
through the archive before sending it to whoever gave you Vedivox.
