# /// script
# requires-python = ">=3.12"
# dependencies = ["pillow"]
# ///
"""Contact sheet of the screen snapshots (VedivoxSnapshotTests): one
row per screen, one column per palette × theme.

    uv run scripts/snapshot_sheet.py                 # contact-sheet.html next to the PNGs
    uv run scripts/snapshot_sheet.py --embed out.html  # standalone page, images inlined
"""

import argparse
import base64
import html
import io
import pathlib
import re

from PIL import Image


SNAPSHOTS = pathlib.Path(__file__).resolve().parent.parent / "Vedivox/VedivoxSnapshotTests/__Snapshots__/ScreenSnapshotTests"
ORDER = ["sidebar-idle", "sidebar-recording", "transcript", "transcript-edit", "series", "speakers", "settings-general"]
COLUMNS = [("mono", "light"), ("mono", "dark"), ("ink", "light"), ("ink", "dark")]
NAME = re.compile(r"^test\w+\.(?P<screen>[\w-]+)_(?P<palette>mono|ink)_(?P<theme>light|dark)\.png$")


def inline(path: pathlib.Path) -> str:
    image = Image.open(path).convert("RGB")
    if image.width > 1400:
        image = image.resize((image.width // 2, image.height // 2), Image.Resampling.LANCZOS)
    buffer = io.BytesIO()
    image.save(buffer, "JPEG", quality=88)
    return "data:image/jpeg;base64," + base64.b64encode(buffer.getvalue()).decode()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--embed", type=pathlib.Path, help="write a standalone page with the images inlined")
    args = parser.parse_args()

    shots: dict[str, dict[tuple[str, str], pathlib.Path]] = {}
    for path in sorted(SNAPSHOTS.glob("*.png")):
        if match := NAME.match(path.name):
            shots.setdefault(match["screen"], {})[(match["palette"], match["theme"])] = path
    if not shots:
        raise SystemExit(f"no snapshots in {SNAPSHOTS} — run make test-snapshots RECORD=1")

    head = "".join(f"<th>{'Ink' if p == 'ink' else 'Mono'} · {t}</th>" for p, t in COLUMNS)
    rows = []
    for screen, cells in sorted(shots.items(), key=lambda kv: ORDER.index(kv[0]) if kv[0] in ORDER else len(ORDER)):
        tds = []
        for column in COLUMNS:
            path = cells.get(column)
            src = (inline(path) if args.embed else path.name) if path else ""
            tds.append(f"<td>{f'<img src={html.escape(src, quote=True)!r} loading=lazy>' if src else '—'}</td>")
        rows.append(f"<tr><th scope=row>{html.escape(screen)}</th>{''.join(tds)}</tr>")

    page = f"""<title>Vedivox Palette Snapshots</title>
<meta name="claude:viewport-fit-sides" content="cover">
<style>
:root {{ --bg: #f4f4f1; --fg: #1a1a1a; --muted: #5c5c57; --line: #dcdcd6 }}
@media (prefers-color-scheme: dark) {{ :root:not([data-theme="light"]) {{ --bg: #111113; --fg: #ecece8; --muted: #9b9b96; --line: #2a2a30; color-scheme: dark }} }}
:root[data-theme="dark"] {{ --bg: #111113; --fg: #ecece8; --muted: #9b9b96; --line: #2a2a30; color-scheme: dark }}
body {{ background: var(--bg); color: var(--fg); font: 13px/1.4 -apple-system, system-ui, sans-serif; padding-block: 24px; padding-left: max(16px, env(safe-area-inset-left, 0px)); padding-right: max(16px, env(safe-area-inset-right, 0px)) }}
h1 {{ font-size: 20px; margin: 0 0 4px }} p {{ color: var(--muted); margin: 0 0 16px; max-width: 80ch }}
.scroll {{ overflow-x: auto }} table {{ border-collapse: collapse }}
th {{ text-align: left; font-weight: 600; padding: 6px 8px; color: var(--muted); white-space: nowrap; vertical-align: top }}
td {{ padding: 6px 8px; vertical-align: top; border-top: 1px solid var(--line) }}
img {{ display: block; width: 420px; max-width: none; border: 1px solid var(--line); border-radius: 6px }}
</style>
<h1>Vedivox — screens in every palette and theme</h1>
<p>Offscreen renders from VedivoxSnapshotTests (make test-snapshots): the app as drawn, not token values. Columns: palette · theme.</p>
<div class="scroll"><table><tr><th></th>{head}</tr>{"".join(rows)}</table></div>
"""
    out = args.embed or SNAPSHOTS / "contact-sheet.html"
    out.write_text(page)
    print(out)


if __name__ == "__main__":
    main()
