#!/bin/bash
# Zoom audio-connect order and coreaudiod timeouts from the unified log.
#
#   scripts/zoom_audio_check.sh "2026-09-28 13:00:00" ["2026-09-28 14:00:00"]
#
# Per zoom.us process: every `setPlayState Started Input/Output` with its time,
# every `the server failed to start` (0x3C timeout). A connection is a run of
# Started lines closer than 5 s to each other; its first line gives the order.
# Verdict: connections with Input first, and the timeout count (spec: ≥ 2 runs
# with Input first, 0 timeouts).
set -euo pipefail
[ $# -ge 1 ] || { echo "usage: $0 <since> [<until>]  (log show date format, e.g. '2026-09-28 13:00:00')" >&2; exit 64; }
args=(--start "$1")
[ $# -ge 2 ] && args+=(--end "$2")

/usr/bin/log show "${args[@]}" --style syslog \
  --predicate 'process == "zoom.us" AND (eventMessage CONTAINS "setPlayState Started" OR eventMessage CONTAINS "the server failed to start")' 2>/dev/null |
awk '
/setPlayState Started|failed to start/ {
    ts = substr($2, 1, 12)
    match($0, /zoom\.us\[[0-9]+\]/); pid = substr($0, RSTART, RLENGTH)
    if (!(pid in seen)) { seen[pid] = 1; order[++n] = pid }
    if ($0 ~ /failed to start/) { kind = "TIMEOUT 0x3C"; timeouts++ }
    else if ($0 ~ /Started  *Input/) kind = "Input"
    else kind = "Output"
    lines[pid] = lines[pid] sprintf("  %s  %s\n", ts, kind)
    if (kind != "TIMEOUT 0x3C") {
        split(ts, t, /[:.]/); sec = t[1] * 3600 + t[2] * 60 + t[3] + t[4] / 1000
        if (!(pid in last) || sec - last[pid] > 5) { conns++; if (kind == "Input") input_first++; else output_first++ }
        last[pid] = sec
    }
}
END {
    for (i = 1; i <= n; i++) printf "%s\n%s", order[i], lines[order[i]]
    printf "verdict: connections=%d (Input first: %d, Output first: %d), timeouts 0x3C: %d\n", conns, input_first, output_first, timeouts
}'
