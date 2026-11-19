# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Synthetic stand-ins for the 30 s test recordings (macOS `say`, no real voice).

Writes test_system_30s.wav (the far side talking for the first half) and
test_mic_30s.wav (the echo of that, then the near side talking) as mono
16 kHz Float32 — the shape AudioGateTests and the smoke UI test expect.

    uv run scripts/synth_test_audio.py Vedivox/VedivoxCoreTests/TestResources
"""

import array
import struct
import subprocess
import sys
import tempfile
import wave
from pathlib import Path

RATE = 16_000
TOTAL = 30 * RATE
HALF = 15 * RATE
FAR_TEXT = (
    "Good morning everyone. Let us walk through the roadmap for the next quarter. "
    "The first milestone is the new onboarding flow, and the second one is the dashboard. "
    "We still need numbers from the beta group before we commit to a date. "
    "I will send the summary after this call."
)
NEAR_TEXT = (
    "Thanks, that works for me. I can prepare the numbers by Thursday, "
    "and I will ping the beta group today so nobody is surprised. "
    "One more thing, the onboarding copy still mentions the old price."
)


def speak(text: str, voice: str) -> list[float]:
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "say.wav"
        subprocess.run(
            ["say", "-v", voice, "-o", str(out), "--file-format=WAVE", f"--data-format=LEI16@{RATE}", text],
            check=True,
        )
        with wave.open(str(out), "rb") as w:
            assert (w.getnchannels(), w.getframerate(), w.getsampwidth()) == (1, RATE, 2)
            pcm = array.array("h", w.readframes(w.getnframes()))
    return [s / 32768 for s in pcm]


def fit(samples: list[float], length: int) -> list[float]:
    return (samples + [0.0] * length)[:length]


def write_float_wav(path: Path, samples: list[float]) -> None:
    data = array.array("f", samples).tobytes()
    fmt = struct.pack("<HHIIHH", 3, 1, RATE, RATE * 4, 4, 32)  # 3 = IEEE float
    body = b"WAVE" + b"fmt " + struct.pack("<I", len(fmt)) + fmt + b"data" + struct.pack("<I", len(data)) + data
    path.write_bytes(b"RIFF" + struct.pack("<I", len(body)) + body)


def main(out_dir: Path) -> None:
    far = fit(fit(speak(FAR_TEXT, "Samantha"), HALF), TOTAL)
    near = [0.0] * HALF + fit(speak(NEAR_TEXT, "Daniel"), HALF)
    delay = RATE * 30 // 1000  # the speaker-to-mic path: 30 ms late, a third as loud
    echo = fit([0.0] * delay + [s * 0.3 for s in far], TOTAL)
    mic = [e + n for e, n in zip(echo, near, strict=True)]
    assert max(map(abs, far)) > 0.05 and max(map(abs, near)) > 0.05, "say produced silence"
    write_float_wav(out_dir / "test_system_30s.wav", far)
    write_float_wav(out_dir / "test_mic_30s.wav", mic)


if __name__ == "__main__":
    main(Path(sys.argv[1]))
