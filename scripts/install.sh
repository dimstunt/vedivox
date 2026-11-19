#!/bin/bash
# Installs or updates Vedivox from an unpacked dist archive: the app, the vedivox CLI
# and the Claude Code skills. Run from anywhere: bash install.sh
set -euo pipefail
cd "$(dirname "$0")"

APPS_DIR="${VEDIVOX_APPS_DIR:-/Applications}"
BIN_DIR="$HOME/.local/bin"
SKILLS_DIR="$HOME/.claude/skills"

mkdir -p "$APPS_DIR" 2>/dev/null || true
[ -w "$APPS_DIR" ] || { echo "✗ $APPS_DIR is not writable — install elsewhere: VEDIVOX_APPS_DIR=\$HOME/Applications bash install.sh"; exit 1; }

# App: replace the bundle, never copy over it (stale files from the old version).
xattr -dr com.apple.quarantine Vedivox.app
rm -rf "$APPS_DIR/Vedivox.app"
ditto Vedivox.app "$APPS_DIR/Vedivox.app"

# CLI: remove first, overwriting a signed binary in place poisons the kernel's
# signature cache and the new binary gets killed on launch. The archive's own
# signature (Developer ID in a notarized zip) is kept; only an unsigned binary
# gets an ad hoc one.
mkdir -p "$BIN_DIR"
rm -f "$BIN_DIR/vedivox"
cp vedivox "$BIN_DIR/vedivox"
xattr -d com.apple.quarantine "$BIN_DIR/vedivox" 2>/dev/null || true
codesign -v "$BIN_DIR/vedivox" 2>/dev/null || codesign -s - --force "$BIN_DIR/vedivox"
rm -f "$BIN_DIR/vedivox-mcp"
cp vedivox-mcp "$BIN_DIR/vedivox-mcp"
xattr -d com.apple.quarantine "$BIN_DIR/vedivox-mcp" 2>/dev/null || true
codesign -v "$BIN_DIR/vedivox-mcp" 2>/dev/null || codesign -s - --force "$BIN_DIR/vedivox-mcp"
# The names the commands had before the rename, where they are free or ours.
sh cli_alias.sh "$BIN_DIR" vedivox vox # rename:keep
sh cli_alias.sh "$BIN_DIR" vedivox-mcp vox-mcp # rename:keep

# Skills: full replace, so files dropped from a skill do not linger.
mkdir -p "$SKILLS_DIR"
for skill in vedivox vedivox-live vedivox-enrich; do
    rm -rf "$SKILLS_DIR/$skill"
    cp -R "skills/$skill" "$SKILLS_DIR/$skill"
done
# The skill under the name it had before the rename, when it is the one the old
# installer put there: /vedivox replaces it, and both would answer the same questions.
old_skill="$SKILLS_DIR/vox" # rename:keep
if grep -qx 'name: vox' "$old_skill/SKILL.md" 2>/dev/null && grep -q 'Bash(vox:' "$old_skill/SKILL.md"; then # rename:keep
    rm -rf "$old_skill"
    echo "✓ $old_skill removed: /vedivox replaces it"
fi

version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APPS_DIR/Vedivox.app/Contents/Info.plist")
echo "✓ Vedivox $version → $APPS_DIR/Vedivox.app"
echo "✓ vedivox CLI and vedivox-mcp server → $BIN_DIR/"
echo "✓ Claude Code skills → $SKILLS_DIR/vedivox, vedivox-live, vedivox-enrich (available as /vedivox, /vedivox-live and /vedivox-enrich in the next session)"

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo "! $BIN_DIR is not in PATH. Add it: echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc" ;;
esac

# The app under the name it had before the rename. The bundle identifier
# decides whether it is ours: on a case-insensitive disk the same path can be
# another app altogether. While it runs it holds the library, so it is left alone.
old_app="$APPS_DIR/Vox.app" # rename:keep
old_running=0
if [ "$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$old_app/Contents/Info.plist" 2>/dev/null)" = "com.dimstunt.Vox" ]; then # rename:keep
    if pgrep -x Vox >/dev/null; then # rename:keep
        old_running=1
        echo "! Vox, as Vedivox used to be called, is still running. Quit it when nothing is recording, delete $old_app and open Vedivox: it takes over your meetings." # rename:keep
    else
        # Out of Launch Services too, not only off the disk: it claimed vox:// links. # rename:keep
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$old_app" 2>/dev/null || true
        rm -rf "$old_app"
        echo "✓ $old_app removed: Vedivox replaces it and takes over your meetings on first launch"
    fi
fi

# A running Vedivox keeps executing the old binary; restarting it would kill a
# recording in progress, so leave that to the user.
if pgrep -x Vedivox >/dev/null; then
    echo "! Vedivox is running the previous version. Quit and reopen it when nothing is recording."
elif [ "$old_running" = 0 ]; then
    open "$APPS_DIR/Vedivox.app"
fi

echo "Vedivox is free and open source. If it helps you, a star helps others find it: https://github.com/@@GITHUB_REPO@@"
