# /// script
# requires-python = ">=3.12"
# dependencies = ["numpy"]
# ///
"""Offset between the system and mic tracks of one recording, measured on a
sound that reached both (e.g. `say` into the built-in speakers).

    uv run scripts/track_offset.py <meetingId-or-prefix> [--json]
    uv run scripts/track_offset.py --system a.m4a --mic b.wav
    uv run scripts/track_offset.py --selftest

Method: 1 ms RMS envelopes of both tracks; the analysis window starts where
the system envelope first crosses --threshold (dBFS); normalized
cross-correlation of the two envelopes inside that window, lag limited to
±--max-lag ms. Positive offset = mic later than system. Decoding goes through
ffmpeg, so wav and m4a both work (AAC priming delay is identical on both
tracks and cancels out).

Exit 0 with a result, 1 when no loud event was found, 64 on bad arguments.
"""

import argparse
import glob
import json
import os
import subprocess
import sys

import numpy as np


SR = 48000
HOP = SR // 1000  # 1 ms
AUDIO_DIR = os.path.expanduser("~/Library/Application Support/Vedivox/audio")


def decode(path: str) -> np.ndarray:
    cmd = ["ffmpeg", "-v", "error", "-i", path, "-f", "f32le", "-ac", "1", "-ar", str(SR), "-"]
    raw = subprocess.run(cmd, check=True, capture_output=True).stdout
    return np.frombuffer(raw, dtype=np.float32).astype(np.float64)


def envelope(x: np.ndarray) -> np.ndarray:
    n = len(x) // HOP
    return np.sqrt((x[: n * HOP].reshape(n, HOP) ** 2).mean(axis=1))


def measure(system: np.ndarray, mic: np.ndarray, threshold_db: float, max_lag_ms: int, window_ms: int) -> dict:
    es, em = envelope(system), envelope(mic)
    thr = 10 ** (threshold_db / 20)
    loud = np.nonzero(es > thr)[0]
    if len(loud) == 0:
        return {"error": f"system track never exceeds {threshold_db} dBFS"}
    t0 = int(loud[0])
    a = max(0, t0 - 500)
    b = min(len(es), t0 + window_ms)
    ref = es[a:b] - es[a:b].mean()
    best, best_lag = -1.0, 0
    corr = []
    for lag in range(-max_lag_ms, max_lag_ms + 1):
        lo, hi = a + lag, b + lag
        if lo < 0 or hi > len(em):
            corr.append(0.0)
            continue
        seg = em[lo:hi] - em[lo:hi].mean()
        denom = np.linalg.norm(ref) * np.linalg.norm(seg)
        c = float(ref @ seg / denom) if denom > 0 else 0.0
        corr.append(c)
        if c > best:
            best, best_lag = c, lag
    # ponytail: 1 ms hop, no sub-ms interpolation; the spec needs ±20 ms.
    mic_loud = np.nonzero(em[a:] > thr)[0]
    onset_mic = int(a + mic_loud[0]) if len(mic_loud) else None
    return {
        "offset_ms": best_lag,
        "confidence": round(best, 3),
        "window_s": [round(a / 1000, 3), round(b / 1000, 3)],
        "onset_system_ms": t0,
        "onset_mic_ms": onset_mic,
        "onset_delta_ms": (onset_mic - t0) if onset_mic is not None else None,
    }


def resolve_meeting(prefix: str) -> tuple[str, str]:
    dirs = [d for d in glob.glob(os.path.join(AUDIO_DIR, prefix.upper() + "*")) if os.path.isdir(d)]
    if len(dirs) != 1:
        sys.exit(f"track_offset: {len(dirs)} meetings match {prefix!r}")
    out = []
    for name in ("system", "mic"):
        cands = [p for p in (os.path.join(dirs[0], name + ext) for ext in (".wav", ".m4a")) if os.path.exists(p)]
        if not cands:
            sys.exit(f"track_offset: no {name}.wav/.m4a in {dirs[0]}")
        out.append(cands[0])
    return out[0], out[1]


def synth(shift_ms: int, seed: int = 1) -> tuple[np.ndarray, np.ndarray]:
    """5 s of silence, then a 'say'-like burst: four AM-shaped noise syllables."""
    rng = np.random.default_rng(seed)
    n = SR * 8
    sig = np.zeros(n)
    t = np.arange(SR * 2) / SR
    env = np.zeros_like(t)
    for k in range(4):
        env += np.exp(-((t - 0.25 - k * 0.45) ** 2) / (2 * 0.06**2))
    sig[SR * 5 : SR * 7] = rng.standard_normal(SR * 2) * env * 0.3
    system = sig
    mic = np.roll(sig, shift_ms * HOP) * 0.2 + rng.standard_normal(n) * 0.003
    return system, mic


def selftest() -> None:
    for shift in (37, -20, 0):
        r = measure(*synth(shift), threshold_db=-30, max_lag_ms=1000, window_ms=2500)
        print(f"shift {shift:+d} ms → {r}")
        assert abs(r["offset_ms"] - shift) <= 2, r
        assert r["confidence"] > 0.9, r
    print("selftest OK")


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("meeting", nargs="?")
    p.add_argument("--system")
    p.add_argument("--mic")
    p.add_argument("--threshold", type=float, default=-30.0, help="dBFS; start of the event on the system track")
    p.add_argument("--max-lag", type=int, default=1000, help="ms")
    p.add_argument("--window", type=int, default=2500, help="ms after the onset")
    p.add_argument("--json", action="store_true")
    p.add_argument("--selftest", action="store_true")
    args = p.parse_args()
    if args.selftest:
        selftest()
        return
    if args.meeting:
        sys_path, mic_path = resolve_meeting(args.meeting)
    elif args.system and args.mic:
        sys_path, mic_path = args.system, args.mic
    else:
        p.error("pass a meeting id, or --system and --mic")
    r = measure(decode(sys_path), decode(mic_path), args.threshold, args.max_lag, args.window)
    r.update({"system": sys_path, "mic": mic_path})
    if args.json:
        print(json.dumps(r))
    elif "error" in r:
        print(r["error"], file=sys.stderr)
    else:
        print(
            f"offset {r['offset_ms']:+d} ms (mic relative to system), confidence {r['confidence']}, "
            f"window {r['window_s'][0]}–{r['window_s'][1]} s, onsets system={r['onset_system_ms']} ms "
            f"mic={r['onset_mic_ms']} ms (delta {r['onset_delta_ms']} ms)"
        )
    sys.exit(1 if "error" in r else 0)


if __name__ == "__main__":
    main()
