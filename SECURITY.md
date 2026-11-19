# Security

## Reporting a vulnerability

Please report it **privately**: on GitHub, open the repository's **Security** tab →
**Report a vulnerability** (a private security advisory). Do not open a public issue. You will
get an answer when the report has been read; Vedivox is maintained by one person, so allow some
days.

Include the Vedivox version (Settings → About), the macOS version and the steps to reproduce.
Never attach real recordings or transcripts.

## Trust model of the command socket

The `vedivox` CLI and the MCP server drive the running app through a Unix socket,
`~/Library/Application Support/Vedivox/command.sock`. Its file permissions keep other users
on the Mac out. Within your own user account it trusts everyone: Vedivox does not check which
program is on the other end — no signature check, no token. Any process running as you can
therefore do whatever the CLI can: start and stop a recording, import or transcribe a file
Vedivox can read, rename speakers, delete meetings. A program without its own microphone
permission could record through Vedivox this way.

What keeps that visible: a recording started through the socket shows a notification,
"Recording started from the command line" (the hotkey, the menu bar and the meeting
auto start do not), and while any recording runs, macOS shows its microphone indicator and
Vedivox its record icon in the menu bar. Turning off Vedivox's notifications in System Settings
hides the first signal.

This is a deliberate trade-off: a process running as you can already read your files,
including Vedivox's data directory, so a stricter socket would mostly add friction for scripts.

## What is in scope

Vedivox runs entirely on your Mac and is not sandboxed, so these are the surfaces that matter:

- **The command socket** — a Unix socket in `~/Library/Application Support/Vedivox/` through
  which the `vedivox` CLI and the MCP server drive the running app. Anything that lets another
  user send commands through it, or starts a recording through it without the notification
  (see the trust model above).
- **The MCP server** (`vedivox-mcp`, stdio) and the `vedivox` CLI — reading or changing meetings
  beyond what a command is meant to do, path traversal in import and export.
- **Import by URL** (`vedivox import <url>`, `vedivox transcribe <url>`) — it runs your own `yt-dlp`
  and `ffmpeg`; argument injection or files written outside the intended place.
- **The `vedivox://` and `vox://` URL schemes** — what a web page or another app can make
  Vedivox do.
- **The update check** — the one request to the GitHub API, and how its answer is shown.
- Local data: the database, audio and voice profiles in
  `~/Library/Application Support/Vedivox/` being readable by other users.

Out of scope: problems that need an attacker who already runs code as you (they can read
your files anyway), and the third-party models and libraries themselves — report those
upstream.
