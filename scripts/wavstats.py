# /// script
# requires-python = ">=3.12"
# dependencies = ["numpy"]
# ///
"""Levels of a WAV by 0.5 s windows, plus the two questions acceptance asks:
where are the all-zero stretches (inserted silence, or HAL zeros) and where is
the loudest moment (the `say` marker). Usage:

    uv run scripts/wavstats.py file.wav            # summary
    uv run scripts/wavstats.py file.wav --zeros    # zero stretches as ranges
    uv run scripts/wavstats.py file.wav --peak-at  # position of the loudest window

m4a → wav first: afconvert -f WAVE -d LEF32@48000 in.m4a out.wav
"""
import struct
import sys

import numpy as np

path = sys.argv[1]
flags = set(sys.argv[2:])
with open(path, "rb") as f:
    data = f.read()
# minimal RIFF walk
pos = 12
fmt = None
pcm = None
while pos + 8 <= len(data):
    cid = data[pos : pos + 4]
    size = struct.unpack("<I", data[pos + 4 : pos + 8])[0]
    body = data[pos + 8 : pos + 8 + size]
    if cid == b"fmt ":
        fmt = struct.unpack("<HHIIHH", body[:16])
    elif cid == b"data":
        pcm = body
    pos += 8 + size + (size & 1)
tag, ch, sr, _, _, bits = fmt
is_float = tag in (3, 65534) and bits == 32
x = np.frombuffer(pcm, dtype=np.float32 if is_float else np.int16).astype(np.float64)
if not is_float:
    x /= 32768
x = x.reshape(-1, ch)
dur = len(x) / sr
rms = np.sqrt((x**2).mean())
peak = np.abs(x).max()
win = int(sr * 0.5)
seg = x[: len(x) - len(x) % win].reshape(-1, win, ch)
segrms = np.sqrt((seg**2).mean(axis=(1, 2)))
segpeak = np.abs(seg).max(axis=(1, 2))
loud = (segrms > 0.01).sum()
name = path.split("/")[-1]
print(f"{name}: {ch} ch, {sr} Hz, {dur:.2f} s, rms={rms:.4f}, peak={peak:.3f}, 0.5s-windows above -40 dBFS: {loud}/{len(segrms)}")

if "--zeros" in flags:
    # Silence fills write digital zero; after the AAC round-trip that decodes
    # to ~1e-7, while a live mic's floor is ~1e-3 (−55 dBFS). 1e-5 separates them.
    zero = segpeak < 1e-5
    start = None
    ranges = []
    for i, z in enumerate(zero):
        if z and start is None:
            start = i
        if not z and start is not None:
            ranges.append((start, i))
            start = None
    if start is not None:
        ranges.append((start, len(zero)))
    total = sum((b - a) for a, b in ranges) * 0.5
    print(f"zero windows: {zero.sum()} × 0.5 s = {total:.1f} s in {len(ranges)} stretch(es)")
    for a, b in ranges:
        print(f"  {a * 0.5:7.1f}–{b * 0.5:7.1f} s  ({(b - a) * 0.5:.1f} s)")

if "--peak-at" in flags:
    i = int(np.argmax(segpeak))
    print(f"loudest window: {i * 0.5:.1f}–{(i + 1) * 0.5:.1f} s, peak={segpeak[i]:.3f}")
