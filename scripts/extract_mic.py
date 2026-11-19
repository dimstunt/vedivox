# /// script
# requires-python = ">=3.12"
# dependencies = [
#     "numpy",
#     "scipy",
#     "soundfile",
# ]
# ///
"""Extract mic-only audio by masking out segments where system audio is active.

Uses energy-based voice activity detection on system.wav to find when remote
speakers are talking, then mutes those segments in the MOV recording to isolate
the local microphone track.
"""

import argparse
import subprocess
import tempfile
from pathlib import Path

import numpy as np
import soundfile as sf


def extract_wav_from_mov(mov_path: Path, wav_path: Path, sr: int = 48000) -> None:
    """Extract audio from MOV to WAV using ffmpeg."""
    subprocess.run(
        [
            "ffmpeg",
            "-y",
            "-i",
            str(mov_path),
            "-vn",
            "-acodec",
            "pcm_f32le",
            "-ar",
            str(sr),
            "-ac",
            "1",  # mono mixdown
            wav_path,
        ],
        check=True,
        capture_output=True,
    )


def compute_energy_mask(
    system: np.ndarray,
    sr: int,
    window_sec: float = 0.05,
    hop_sec: float = 0.025,
    threshold_factor: float = 3.0,
    fade_sec: float = 0.01,
) -> np.ndarray:
    """Compute a per-sample energy mask from system audio.

    Returns a float32 array (same length as system) where:
    - 0.0 = system audio active (mute this in mixed)
    - 1.0 = system audio silent (keep this in mixed)

    All operations are vectorized numpy — no Python loops over samples.
    """
    window_samples = int(window_sec * sr)
    hop_samples = int(hop_sec * sr)

    # Compute RMS energy per frame using stride tricks for efficiency
    n_frames = (len(system) - window_samples) // hop_samples + 1
    frames = np.lib.stride_tricks.as_strided(
        system,
        shape=(n_frames, window_samples),
        strides=(system.strides[0] * hop_samples, system.strides[0]),
    )
    energy = np.sqrt(np.mean(frames.astype(np.float64) ** 2, axis=1)).astype(np.float32)

    # Adaptive threshold: use gap between silence and speech energy.
    # P50 is typically noise, P75 is where speech starts.
    # Use geometric mean of P50 and P75 as threshold, scaled by factor.
    p50 = float(np.percentile(energy, 50))
    p75 = float(np.percentile(energy, 75))
    if p50 > 0 and p75 > p50 * 10:
        # Bimodal: clear gap between noise and speech
        threshold = np.sqrt(p50 * p75) * threshold_factor
    else:
        # Fallback: use absolute threshold based on energy distribution
        threshold = max(p75 * 0.1 * threshold_factor, 1e-4)
    noise_floor = p50

    # Binary activity: 1 = system speaking, 0 = silent
    activity = (energy > threshold).astype(np.float32)

    print(f"  Energy frames: {n_frames}, noise floor: {noise_floor:.6f}, threshold: {threshold:.6f}")
    print(f"  Active frames: {int(np.sum(activity))}/{n_frames} ({np.mean(activity) * 100:.1f}%)")

    # Upsample frame-level activity to sample-level using repeat
    # Each frame covers hop_samples, last frame extended to fill
    mask_upsampled = np.repeat(activity, hop_samples)
    # Trim or pad to match system length
    if len(mask_upsampled) < len(system):
        mask_upsampled = np.concatenate(
            [
                mask_upsampled,
                np.full(len(system) - len(mask_upsampled), activity[-1]),
            ]
        )
    else:
        mask_upsampled = mask_upsampled[: len(system)]

    # Invert: we want 1.0 where system is SILENT (keep user voice)
    mask = 1.0 - mask_upsampled

    # Smooth with a fade kernel (vectorized convolution instead of per-sample loop)
    fade_samples = max(int(fade_sec * sr), 1)
    kernel = np.ones(fade_samples * 2, dtype=np.float32) / (fade_samples * 2)
    mask_smooth = np.convolve(mask, kernel, mode="same").astype(np.float32)

    # Clamp to [0, 1]
    np.clip(mask_smooth, 0.0, 1.0, out=mask_smooth)

    return mask_smooth


def apply_mask(
    mixed: np.ndarray,
    system: np.ndarray,
    offset: int,
    mask: np.ndarray,
) -> np.ndarray:
    """Apply the energy mask to the mixed audio.

    offset: system audio starts `offset` samples BEFORE mixed audio.
    i.e., mixed[0] corresponds to system[offset].
    """
    result = mixed.copy().astype(np.float32)

    # Map mask (aligned with system) onto mixed
    # mixed[i] <-> system[i + offset]
    for i_mix in range(len(mixed)):
        i_sys = i_mix + offset
        if 0 <= i_sys < len(mask):
            result[i_mix] *= mask[i_sys]
        # else: outside system range, keep original (user might be speaking)

    return result


def apply_mask_vectorized(
    mixed: np.ndarray,
    system: np.ndarray,
    offset: int,
    mask: np.ndarray,
) -> np.ndarray:
    """Apply the energy mask to the mixed audio (vectorized).

    offset: system[offset] corresponds to mixed[0].
    i.e., mixed[i] <-> system[i + offset].
    """
    result = mixed.copy().astype(np.float32)

    # Compute the overlap region
    # mixed[i] <-> mask[i + offset]
    mix_start = max(0, -offset)
    mix_end = min(len(mixed), len(mask) - offset)
    mask_start = mix_start + offset
    mask_end = mix_end + offset

    if mix_start < mix_end:
        result[mix_start:mix_end] *= mask[mask_start:mask_end]

    print(f"  Mask applied to samples {mix_start}..{mix_end} of mixed ({(mix_end - mix_start) / 48000:.1f} sec)")

    return result


def main() -> None:
    parser = argparse.ArgumentParser(description="Extract mic audio by masking segments where system audio is active")
    parser.add_argument("mov_path", type=Path, help="Path to MOV file with all voices")
    parser.add_argument("system_path", type=Path, help="Path to system.wav (other voices only)")
    parser.add_argument("output_path", type=Path, help="Output path for extracted mic audio")
    parser.add_argument("--sr", type=int, default=48000, help="Sample rate (default: 48000)")
    parser.add_argument(
        "--offset",
        type=float,
        default=None,
        help="Manual offset in seconds (system started N sec before MOV). Positive = system leads MOV.",
    )
    parser.add_argument("--threshold", type=float, default=3.0, help="Energy threshold factor (default: 3.0)")
    parser.add_argument("--window", type=float, default=0.05, help="Analysis window in seconds (default: 0.05)")
    parser.add_argument("--fade", type=float, default=0.01, help="Fade duration in seconds (default: 0.01)")
    args = parser.parse_args()

    print(f"1. Extracting audio from {args.mov_path.name}...")
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        tmp_path = Path(tmp.name)
    extract_wav_from_mov(args.mov_path, tmp_path, args.sr)

    print("2. Loading audio files...")
    mixed, sr_mix = sf.read(tmp_path)
    system, sr_sys = sf.read(args.system_path)

    # Convert to mono if needed
    if mixed.ndim > 1:
        mixed = np.mean(mixed, axis=1).astype(np.float32)
    if system.ndim > 1:
        system = np.mean(system, axis=1).astype(np.float32)

    print(f"  Mixed: {len(mixed) / sr_mix:.1f} sec ({len(mixed)} samples)")
    print(f"  System: {len(system) / sr_sys:.1f} sec ({len(system)} samples)")

    # Offset: how many samples into system corresponds to mixed[0]
    if args.offset is not None:
        offset_samples = int(args.offset * args.sr)
        print(f"3. Using manual offset: {args.offset:.3f} sec ({offset_samples} samples)")
    else:
        print("3. No offset specified, assuming aligned start (offset=0)")
        offset_samples = 0

    print("4. Computing energy mask from system audio...")
    mask = compute_energy_mask(
        system,
        args.sr,
        window_sec=args.window,
        threshold_factor=args.threshold,
        fade_sec=args.fade,
    )

    print("5. Applying mask to mixed audio...")
    result = apply_mask_vectorized(mixed, system, offset_samples, mask)

    # Normalize
    peak = np.max(np.abs(result))
    if peak > 0.95:
        result *= 0.95 / peak
        print(f"  Normalized output (peak was {peak:.3f})")

    print(f"6. Saving to {args.output_path}...")
    sf.write(str(args.output_path), result, args.sr)

    tmp_path.unlink()

    duration = len(result) / args.sr
    silence_ratio = 1.0 - np.mean(mask[offset_samples : offset_samples + len(mixed)])
    print(f"\nDone! Output: {duration:.1f} sec, ~{silence_ratio * 100:.0f}% muted (other speakers)")


if __name__ == "__main__":
    main()
