#!/bin/bash
# Live acceptance for an earlier change, sections 3.2 and 3.3.
#
#   scripts/acceptance_tap_eager.sh --dry-run
#   scripts/acceptance_tap_eager.sh 3.2 [--out DIR] [--speakers "MacBook Pro Speakers"]
#   scripts/acceptance_tap_eager.sh 3.3 [--minutes 10] [--out DIR]
#
# Recording is started/stopped through `vedivox record start|stop` when that
# subcommand exists in the installed vedivox; otherwise the script prints the step
# and waits for Enter (start/stop from the menu bar). Everything lands in the
# report directory: hal_state snapshots, vedivox.log slices, track_offset output,
# summary.txt with the verdict.
set -uo pipefail
cd "$(dirname "$0")/.."

LOG="$HOME/Library/Application Support/Vedivox/logs/vedivox.log"
AUDIO="$HOME/Library/Application Support/Vedivox/audio"
VEDIVOX="${VEDIVOX_BIN:-vedivox}"
MODE="" OUT="" MINUTES=10 SPEAKERS="MacBook Pro Speakers" DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    3.2|3.3) MODE=$1 ;;
    --dry-run) DRY=1 ;;
    --out) OUT=$2; shift ;;
    --minutes) MINUTES=$2; shift ;;
    --speakers) SPEAKERS=$2; shift ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
  shift
done
[ -n "$MODE" ] || [ $DRY = 1 ] || { echo "usage: $0 3.2|3.3|--dry-run [--out DIR] [--minutes N] [--speakers NAME]" >&2; exit 64; }
OUT=${OUT:-"acceptance-tap-eager-$(date +%Y%m%d-%H%M%S)"}

say_() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$OUT/summary.txt"; }
# `vedivox record --help` exits 0 even without the subcommand (root help), so look at the subcommand list.
have_record=0; "$VEDIVOX" --help 2>/dev/null | grep -qE '^\s+record\b' && have_record=1

# ---- preflight -------------------------------------------------------------
mkdir -p "$OUT"
say_ "report dir: $OUT"
for tool in ffmpeg SwitchAudioSource uv swift "$VEDIVOX"; do
  command -v "$tool" >/dev/null || { say_ "missing tool: $tool"; [ $DRY = 1 ] || exit 3; }
done
say_ "vedivox record start/stop: $([ $have_record = 1 ] && echo available || echo 'NOT available → manual start/stop prompts')"
if [ $DRY = 1 ]; then
  say_ "dry-run: selftest of track_offset"
  uv run scripts/track_offset.py --selftest | tail -1 | tee -a "$OUT/summary.txt"
  say_ "dry-run: plan for 3.2 — 3 × (hal_state; output → '$SPEAKERS'; start; sleep 5; say; sleep 2; stop; wait m4a; track_offset)"
  say_ "dry-run: plan for 3.3 — hal_state; start; $MINUTES min idle with hal_state at mid-point; stop; log slice: lengths vs wall clock, Padded, Measured sample rate; wavstats --zeros"
  say_ "dry-run: current output = $(SwitchAudioSource -c -t output 2>/dev/null); not switching"
  exit 0
fi

# ---- helpers ---------------------------------------------------------------
hal() { swift scripts/hal_state.swift > "$OUT/$1" 2>&1; grep -c 'running=1' "$OUT/$1" | xargs -I{} echo "  $1: {} device(s)/proc(s) running" | tee -a "$OUT/summary.txt"; }

rec_start() { # $1 title → sets MEETING
  if [ $have_record = 1 ]; then
    MEETING=$("$VEDIVOX" record start --title "$1" | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' | head -1)
  else
    read -r -p ">>> START recording from the Vedivox menu bar, then press Enter " _
    sleep 2; MEETING=$("$VEDIVOX" status --json | python3 -c 'import json,sys; r=json.load(sys.stdin).get("recording"); print(r["id"] if r else "")')
  fi
  [ -n "$MEETING" ] || { say_ "no recording found after start"; exit 3; }
  T_START=$(date '+%Y-%m-%d %H:%M:%S')
  say_ "recording $MEETING started ($1)"
}
rec_stop() {
  if [ $have_record = 1 ]; then "$VEDIVOX" record stop >/dev/null; else read -r -p ">>> STOP recording from the Vedivox menu bar, then press Enter " _; fi
  T_STOP=$(date '+%Y-%m-%d %H:%M:%S')
  say_ "recording $MEETING stopped"
}
wait_files() { # m4a appear after post-processing; wav is gone by then
  for _ in $(seq 1 120); do [ -f "$AUDIO/$MEETING/system.m4a" ] && [ -f "$AUDIO/$MEETING/mic.m4a" ] && return 0; sleep 1; done
  say_ "timeout waiting for m4a in $AUDIO/$MEETING"; return 1
}
log_slice() { # $1 file: lines between T_START-2s and T_STOP+5s (string compare on the timestamp prefix works for one day)
  awk -v a="$T_START" -v b="$T_STOP" 'substr($0,1,19) >= a && substr($0,1,19) <= b' "$LOG" > "$OUT/$1"
}

# ---- 3.2 track alignment ---------------------------------------------------
if [ "$MODE" = 3.2 ]; then
  PREV_OUT=$(SwitchAudioSource -c -t output); trap 'SwitchAudioSource -t output -s "$PREV_OUT" >/dev/null' EXIT
  SwitchAudioSource -t output -s "$SPEAKERS" >/dev/null || { say_ "cannot select output '$SPEAKERS' (see SwitchAudioSource -a -t output)"; exit 3; }
  offsets=()
  for i in 1 2 3; do
    hal "hal_before_$i.txt"
    rec_start "acceptance 3.2 run $i"
    sleep 5
    say "acceptance run $i, marker $i"
    sleep 2
    rec_stop
    log_slice "run_$i.log"
    wait_files || continue
    grep -h 'First callback after\|Mic first frame\|Padded\|Prepended' "$OUT/run_$i.log" | sed 's/^/  /' | tee -a "$OUT/summary.txt"
    r=$(uv run scripts/track_offset.py "$MEETING" --json | tee "$OUT/offset_$i.json")
    off=$(echo "$r" | python3 -c 'import json,sys; r=json.load(sys.stdin); print(r.get("offset_ms","NA"), r.get("confidence","NA"))')
    say_ "run $i: offset/confidence = $off"
    offsets+=("${off%% *}")
    [ $i -lt 3 ] && sleep 3
  done
  python3 - "${offsets[@]}" <<'EOF' | tee -a "$OUT/summary.txt"
import sys
v = [int(x) for x in sys.argv[1:] if x != "NA"]
spread = max(v) - min(v) if v else None
print(f"3.2 offsets ms: {v}, spread {spread} ms → {'PASS' if v and len(v) == 3 and spread <= 20 else 'FAIL'} (spec: spread ≤ 20 ms over 3 runs)")
EOF
fi

# ---- 3.3 silence and drift -------------------------------------------------
if [ "$MODE" = 3.3 ]; then
  hal "hal_before.txt"
  rec_start "acceptance 3.3 silence $MINUTES min"
  say_ "idle for $MINUTES min — no sound, no output switches"
  sleep $((MINUTES * 30)); hal "hal_mid.txt"; sleep $((MINUTES * 30))
  rec_stop
  log_slice "run.log"
  hal "hal_after.txt"
  python3 - "$OUT/run.log" "$MEETING" <<'EOF' | tee -a "$OUT/summary.txt"
import re, sys
from datetime import datetime
log = open(sys.argv[1]).read()
def t(pat):
    m = re.search(r"^(\S+ \S+) .*" + pat, log, re.M)
    return datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S.%f") if m else None
def f(pat):
    m = re.search(pat, log); return float(m.group(1)) if m else None
start, stop = t(r"Starting system audio capture to .*" + sys.argv[2]), t(r"Capture stopped, file: .*" + sys.argv[2])
wall = (stop - start).total_seconds() if start and stop else None
sysl = f(r"\[SystemAudioCapture\] Total frames written: \d+ \(([\d.]+) sec")
micl = f(r"\[MicrophoneCapture\] Total frames written: \d+ \(([\d.]+) sec")
pad = f(r"Padded \d+ silence frames \(([\d.]+) sec\) at stop") or 0.0
rate = f(r"Measured sample rate: (\d+) Hz")
ok = wall and sysl and micl and abs(sysl - wall) <= 0.2 and abs(micl - wall) <= 0.2 and pad <= 0.2 and rate in (47999, 48000)
print(f"3.3 wall {wall} s, system {sysl} s, mic {micl} s, padded {pad} s, measured rate {rate} Hz → {'PASS' if ok else 'FAIL'}")
EOF
  if wait_files; then
    for tr in system mic; do
      ffmpeg -v error -y -i "$AUDIO/$MEETING/$tr.m4a" -c:a pcm_f32le "$OUT/$tr.wav"
      uv run scripts/wavstats.py "$OUT/$tr.wav" --zeros | head -2 | sed 's/^/  /' | tee -a "$OUT/summary.txt"
    done
    say_ "wavstats: system windows must all be zero (m4a round-trip: peak < 1e-5); mic windows carry the room floor, not zeros"
  fi
  say_ "hal_state: check hal_mid.txt has no output device with running=1 (aggregate/tap of Vedivox excluded)"
fi
say_ "done → $OUT/summary.txt"
