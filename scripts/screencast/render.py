# /// script
# requires-python = ">=3.12"
# dependencies = [
#     "websockets",
# ]
# ///
"""Renders the Vedivox screencast and the landing loops.

composition.html draws any moment of the film on request; this script asks
headless Chrome for one frame after another over the DevTools protocol and
pipes them to ffmpeg. Frames come from `make screencast-frames`.

    make screencast                 # everything
    make screencast ONLY=film       # one of: film, hero-dark, hero-light, live-dark, ...

Needs Google Chrome and ffmpeg.
"""

import argparse
import asyncio
import base64
import json
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path

import websockets


HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
REFERENCES = REPO / "Vedivox/VedivoxSnapshotTests/__Snapshots__/ScreenSnapshotTests"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
FPS = 30


@dataclass(frozen=True)
class Variant:
    view: str
    theme: str
    width: int
    height: int
    scale: int
    outputs: tuple[str, ...]


# Loop sizes are the landing's frames: 2360:1100 (first screen) and 1520:520 (live text). The landing
# takes the files by these names from the output folder.
VARIANTS: dict[str, Variant] = {
    "film": Variant("film", "dark", 1920, 1080, 1, ("vedivox-screencast.mp4",)),
    "hero-dark": Variant("hero", "dark", 1180, 550, 2, ("loop-hero-dark.mp4", "loop-hero-dark.webm")),
    "hero-light": Variant("hero", "light", 1180, 550, 2, ("loop-hero-light.mp4", "loop-hero-light.webm")),
    "live-dark": Variant("live", "dark", 760, 260, 2, ("loop-live-dark.mp4", "loop-live-dark.webm", "readme-live.gif")),
    "live-light": Variant("live", "light", 760, 260, 2, ("loop-live-light.mp4", "loop-live-light.webm")),
}

ENCODERS: dict[str, tuple[str, ...]] = {
    ".mp4": ("-c:v", "libx264", "-preset", "slow", "-crf", "20", "-pix_fmt", "yuv420p", "-movflags", "+faststart"),
    ".webm": ("-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-pix_fmt", "yuv420p", "-row-mt", "1"),
    ".gif": (
        "-filter_complex",
        "[0:v]fps=12,scale=1140:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5",
    ),
}


class Chrome:
    """One page of a headless Chrome, driven over the DevTools protocol."""

    def __init__(self, socket: websockets.ClientConnection, session: str) -> None:
        self._socket = socket
        self._session = session
        self._last_id = 0

    async def call(self, method: str, params: dict | None = None, session: bool = True) -> dict:
        self._last_id += 1
        message = {"id": self._last_id, "method": method, "params": params or {}}
        if session:
            message["sessionId"] = self._session
        await self._socket.send(json.dumps(message))
        while True:
            reply = json.loads(await self._socket.recv())
            if reply.get("id") != self._last_id:
                continue  # an event, nobody listens
            if "error" in reply:
                raise RuntimeError(f"{method}: {reply['error']}")
            return reply["result"]

    async def evaluate(self, expression: str) -> object:
        result = await self.call(
            "Runtime.evaluate", {"expression": expression, "awaitPromise": True, "returnByValue": True}
        )
        if "exceptionDetails" in result:
            raise RuntimeError(f"{expression}: {result['exceptionDetails']}")
        return result["result"].get("value")


def start_chrome(profile: Path) -> tuple[subprocess.Popen[str], str]:
    process = subprocess.Popen(
        [CHROME, "--headless=new", "--remote-debugging-port=0", f"--user-data-dir={profile}",
         "--hide-scrollbars", "--no-first-run", "about:blank"],
        stderr=subprocess.PIPE, stdout=subprocess.DEVNULL, text=True,
    )  # fmt: skip
    assert process.stderr is not None
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        line = process.stderr.readline()
        if "DevTools listening on " in line:
            return process, line.split("DevTools listening on ", 1)[1].strip()
        if not line and process.poll() is not None:
            break
    process.kill()
    raise RuntimeError("Chrome did not start")


async def render(chrome: Chrome, name: str, variant: Variant, frames: Path, out: Path) -> None:
    await chrome.call(
        "Emulation.setDeviceMetricsOverride",
        {"width": variant.width, "height": variant.height, "deviceScaleFactor": variant.scale, "mobile": False},
    )
    page = (HERE / "composition.html").as_uri()
    await chrome.call(
        "Page.navigate",
        {"url": f"{page}?v={variant.view}&theme={variant.theme}&frames={frames.as_uri()}&refs={REFERENCES.as_uri()}"},
    )
    for _ in range(200):  # the new document replaces the old one a moment after navigate returns
        try:
            if await chrome.evaluate(
                f"window.SC && location.search.includes('v={variant.view}&theme={variant.theme}')"
            ):
                break
        except RuntimeError:
            pass
        await asyncio.sleep(0.05)
    else:
        raise RuntimeError(f"{name}: composition.html did not load")
    duration = await chrome.evaluate("SC.ready.then(() => SC.duration)")
    assert isinstance(duration, int | float)

    encoders = [
        subprocess.Popen(
            [
                "ffmpeg",
                "-y",
                "-loglevel",
                "error",
                "-f",
                "image2pipe",
                "-framerate",
                str(FPS),
                "-c:v",
                "png",
                "-i",
                "-",
                *ENCODERS[Path(output).suffix],
                str(out / output),
            ],
            stdin=subprocess.PIPE,
        )  # fmt: skip
        for output in variant.outputs
    ]
    count = round(duration * FPS)
    for index in range(count):
        await chrome.evaluate(f"SC.seek({index / FPS})")
        shot = await chrome.call("Page.captureScreenshot", {"format": "png"})
        png = base64.b64decode(shot["data"])
        if index == 0 and variant.view != "film":
            (out / f"loop-{name}-poster.png").write_bytes(png)  # a loop opens on its poster frame
        for encoder in encoders:
            assert encoder.stdin is not None
            encoder.stdin.write(png)
        if index % FPS == 0:
            print(f"\r{name}: {index // FPS}/{round(duration)} s", end="", flush=True)
    for encoder, output in zip(encoders, variant.outputs, strict=True):
        assert encoder.stdin is not None
        encoder.stdin.close()
        if encoder.wait() != 0:
            raise RuntimeError(f"ffmpeg failed on {output}")
    sizes = ", ".join(f"{output} {(out / output).stat().st_size / 1e6:.2f} MB" for output in variant.outputs)
    print(f"\r{name}: {count} frames -> {sizes}")


async def main() -> int:
    parser = argparse.ArgumentParser(description="Renders the Vedivox screencast and the landing loops.")
    parser.add_argument("--frames", type=Path, required=True, help="PNG frames of make screencast-frames")
    parser.add_argument("--out", type=Path, required=True, help="where the videos go")
    parser.add_argument("--only", choices=sorted(VARIANTS), help="render one variant")
    args = parser.parse_args()
    frames: Path = args.frames.expanduser().resolve()
    out: Path = args.out.expanduser().resolve()
    if not (frames / "frame.live_dark_0.png").exists():
        print(f"no frames in {frames}: run make screencast-frames first", file=sys.stderr)
        return 1
    out.mkdir(parents=True, exist_ok=True)

    profile = Path(tempfile.mkdtemp(prefix="vedivox-screencast-chrome-"))
    process, endpoint = start_chrome(profile)
    try:
        async with websockets.connect(endpoint, max_size=None) as socket:
            browser = Chrome(socket, "")
            target = await browser.call("Target.createTarget", {"url": "about:blank"}, session=False)
            attached = await browser.call(
                "Target.attachToTarget", {"targetId": target["targetId"], "flatten": True}, session=False
            )
            chrome = Chrome(socket, attached["sessionId"])
            for name, variant in VARIANTS.items():
                if args.only in (None, name):
                    await render(chrome, name, variant, frames, out)
    finally:
        process.terminate()
        process.wait()
        shutil.rmtree(profile, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
