# /// script
# requires-python = ">=3.12"
# dependencies = ["pillow"]
# ///
"""Vedivox sign N2 «Фокус»: a V of two strokes on an ink plate, the left
one yellow («я»), the right one paper («они»), the red recording dot under the tip.

Writes every PNG AppIcon.appiconset lists and the README header (the icon beside the
word, dark and light), all from the numbers below:

    uv run scripts/app_icon.py

The 16 pt icon (16 and 32 px files) takes the small cut F0: the strokes meet in a
closed V, and the dot sits on its tip in a ring of plate colour. Every other size takes
the big drawing. Files of 32 px and less have no shadow and their plate edges on the
pixel grid. The status bar draws the small cut in Swift, `MenuBarGlyph.swift`.

Coordinates are the 1024 canvas of the macOS icon grid. Colours are the Ink palette's
dark tokens as sRGB: plate `bg`, rim `line`, yellow `accent`, paper, `recording`.
"""

import math
import pathlib

from PIL import Image, ImageDraw, ImageFilter


ROOT = pathlib.Path(__file__).resolve().parent.parent
ICONS = ROOT / "Vedivox/Vedivox/Assets.xcassets/AppIcon.appiconset"
IMAGES = ROOT / "docs/images"
# (file, pixels, small cut F0): what AppIcon.appiconset/Contents.json lists.
FILES = (
    ("icon_16.png", 16, True),
    ("icon_16@2x.png", 32, True),
    ("icon_32.png", 32, False),
    *((f"icon_{n}.png", n, False) for n in (64, 128, 256, 512, 1024)),
)
GRID_UP_TO = 32

INK = "#111419"  # oklch(0.19 0.012 265)
RIM = "#3b434d"  # oklch(0.38 0.02 250)
YELLOW = "#e2cc47"  # oklch(0.84 0.15 100)
PAPER = "#f4f3e0"  # oklch(0.96 0.025 103)
REC = "#f84b4b"  # oklch(0.66 0.21 25)
FG_LIGHT = "#181b20"  # text on a light page

# Big drawing: plate (x0, y0, x1, y1, radius, rim), two strokes from the free end down, the dot.
PLATE = (100, 100, 924, 924, 185, 4)
STROKE_W = 96
LEFT, RIGHT = ((281, 270), (450, 614)), ((743, 270), (574, 614))
DOT, DOT_R = (512, 740), 64
# Small plate: edges on the 32 px grid. Small cut F0: the strokes closed at the tip,
# a hole of plate colour around the tip and the dot in it.
SMALL_PLATE = (96, 96, 928, 928, 188, 8)
SMALL_W = 128
SMALL_LEFT, SMALL_RIGHT, TIP = (264, 272), (760, 272), (512, 704)
HOLE_R, SMALL_DOT_R = 132, 104


def render(size: int, small: bool = False) -> Image.Image:
    grid = size <= GRID_UP_TO
    # Grid sizes are averaged down from the full canvas: every pixel is its true coverage.
    ss = 1024 // size if grid else 4
    k = size * ss / 1024

    def s(*v: float) -> list[float]:
        return [x * k for x in v]

    canvas = Image.new("RGBA", (size * ss, size * ss), (0, 0, 0, 0))
    x0, y0, x1, y1, radius, rim = SMALL_PLATE if grid else PLATE
    if not grid:  # at 32 px and less the shadow only blurs the edge
        shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
        ImageDraw.Draw(shadow).rounded_rectangle(s(x0, y0 + 12, x1, y1 + 12), radius * k, fill=(0, 0, 0, 90))
        canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(14 * k)))
    d = ImageDraw.Draw(canvas)
    # Pillow's box includes its last pixel: x1 - 1 on the canvas is the plate edge x1.
    box = [*s(x0, y0), *(v - 1 for v in s(x1, y1))]
    d.rounded_rectangle(box, radius * k, fill=INK, outline=RIM, width=max(1, round(rim * k)))

    def stroke(draw: ImageDraw.ImageDraw, a: tuple[float, float], b: tuple[float, float], w: float, fill: str) -> None:
        draw.line(s(*a, *b), fill=fill, width=round(w * k))
        for x, y in (a, b):
            draw.ellipse(s(x - w / 2, y - w / 2, x + w / 2, y + w / 2), fill=fill)

    def dot(cx: float, cy: float, r: float, fill: str) -> None:
        d.ellipse(s(cx - r, cy - r, cx + r, cy + r), fill=fill)

    if small:
        # Each half is its stroke cut along the vertical through the tip, so the colours meet on a seam.
        seam = round(TIP[0] * k)
        for end, fill, box in (
            (SMALL_LEFT, YELLOW, (0, 0, seam, canvas.height)),
            (SMALL_RIGHT, PAPER, (seam, 0, *canvas.size)),
        ):
            layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
            stroke(ImageDraw.Draw(layer), end, TIP, SMALL_W, fill)
            canvas.alpha_composite(layer.crop(box), dest=box[:2])
        dot(*TIP, HOLE_R, INK)
        dot(*TIP, SMALL_DOT_R, REC)
        return canvas.reduce(ss)
    for top, bottom, fill in ((*LEFT, YELLOW), (*RIGHT, PAPER)):
        stroke(d, top, bottom, STROKE_W, fill)
    dot(*DOT, DOT_R, REC)
    return canvas.reduce(ss) if grid else canvas.resize((size, size), Image.Resampling.LANCZOS)


# ── The word ───────────────────────────────────────────────────────────────────────────
# Lowercase «vedivox» in the stroke of the sign: 22 units, x-height 100 with the baseline
# at 100 and the x-line at 0. v takes the slope of the sign, the dot of i is the dot of the
# sign mirrored upwards: the same radius and the same gap to its stroke, in red.
WORD_W = 22
SCALE = STROKE_W / WORD_W  # sign units per word unit
V_RUN = 78 * (LEFT[1][0] - LEFT[0][0]) / (LEFT[1][1] - LEFT[0][1])
I_DOT_R = DOT_R / SCALE
I_DOT_GAP = (math.hypot(DOT[0] - LEFT[1][0], DOT[1] - LEFT[1][1]) - STROKE_W / 2 - DOT_R) / SCALE


def n(x: float) -> str:
    return f"{x:.1f}".rstrip("0").rstrip(".")


def path(d: str, c: str) -> str:
    return f'<path d="{d}" fill="none" stroke="{c}" stroke-width="{WORD_W}" stroke-linecap="round" stroke-linejoin="round"/>'


def ring(cx: float, c: str) -> str:
    return f'<circle cx="{n(cx)}" cy="50" r="39" fill="none" stroke="{c}" stroke-width="{WORD_W}"/>'


def letter(ch: str, x: float, c: str) -> tuple[float, str]:
    """(advance, svg) of a letter whose left ink edge is at x."""
    match ch:
        case "v":
            return 2 * V_RUN + 22, path(f"M{n(x + 11)} 11L{n(x + 11 + V_RUN)} 89L{n(x + 11 + 2 * V_RUN)} 11", c)
        case "e":
            end = f"{n(x + 50 + 39 * math.cos(0.72))} {n(50 + 39 * math.sin(0.72))}"
            return 100, path(f"M{n(x + 11)} 50H{n(x + 89)}A39 39 0 1 0 {end}", c)
        case "d":
            return 100, ring(x + 50, c) + path(f"M{n(x + 89)} -39V89", c)
        case "i":
            stem = path(f"M{n(x + 11)} 11V89", c)
            return 22, stem + f'<circle cx="{n(x + 11)}" cy="{n(-I_DOT_GAP - I_DOT_R)}" r="{n(I_DOT_R)}" fill="{REC}"/>'
        case "o":
            return 100, ring(x + 50, c)
        case "x":
            return 86, path(f"M{n(x + 11)} 11L{n(x + 75)} 89M{n(x + 75)} 11L{n(x + 11)} 89", c)
    raise ValueError(ch)


# Gap before each letter, in word units.
WORD = (("v", 0), ("e", 2), ("d", 13), ("i", 22), ("v", 14), ("o", 2), ("x", 8))


def run(letters: tuple[tuple[str, int], ...], x: float, fg: str) -> tuple[float, str]:
    """(right ink edge, svg) of letters set from x."""
    word = ""
    for ch, gap in letters:
        x += gap
        advance, svg = letter(ch, x, fg)
        word += svg
        x += advance
    return x, word


def wordmark_svg(fg: str) -> str:
    """The word with the sign for its first letter (owner, 2026-11-18): the two strokes and the
    dot without the plate, at the stroke of the word, the dot standing on the baseline. «They»
    take the colour of the text; «edivox» sits as close to the right stroke as to a lowercase v."""

    def at(p: tuple[float, float]) -> tuple[float, float]:
        return (p[0] - LEFT[0][0] + STROKE_W / 2) / SCALE, 100 - (DOT[1] + DOT_R - p[1]) / SCALE

    sign = ""
    for stroke, c in ((LEFT, YELLOW), (RIGHT, fg)):
        (ax, ay), (bx, by) = map(at, stroke)
        sign += path(f"M{n(ax)} {n(ay)}L{n(bx)} {n(by)}", c)
    cx, cy = at(DOT)
    sign += f'<circle cx="{n(cx)}" cy="{n(cy)}" r="{n(I_DOT_R)}" fill="{REC}"/>'
    # The right stroke where the arm of a lowercase v ends (y 11), plus half a stroke: the edge the next letter is set from.
    edge = bx + (ax - bx) * (by - 11) / (by - ay) + WORD_W / 2
    width, word = run(WORD[1:], edge, fg)
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="-2 -52 {n(width + 4)} 154" role="img" aria-label="Vedivox">'
        f"{sign}{word}</svg>\n"
    )


def header_svg(fg: str) -> str:
    """The icon (200 units, the big drawing) and the word beside it at half scale."""
    x, word = run(WORD, 0.0, fg)
    width = 212 + x * 0.5 + 6
    x0, y0, x1, y1, radius, rim = PLATE
    icon = (
        f'<rect x="{x0}" y="{y0}" width="{x1 - x0}" height="{y1 - y0}" rx="{radius}" fill="{INK}"/>'
        f'<rect x="{x0 + rim / 2}" y="{y0 + rim / 2}" width="{x1 - x0 - rim}" height="{y1 - y0 - rim}"'
        f' rx="{radius - rim / 2}" fill="none" stroke="{RIM}" stroke-width="{rim}"/>'
        + "".join(
            f'<path d="M{a[0]} {a[1]}L{b[0]} {b[1]}" stroke="{c}" stroke-width="{STROKE_W}" stroke-linecap="round"/>'
            for (a, b), c in ((LEFT, YELLOW), (RIGHT, PAPER))
        )
        + f'<circle cx="{DOT[0]}" cy="{DOT[1]}" r="{DOT_R}" fill="{REC}"/>'
    )
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {n(width)} 200" role="img" aria-label="Vedivox">\n'
        f'<svg width="200" height="200" viewBox="0 0 1024 1024">{icon}</svg>\n'
        f'<g transform="translate(212 76) scale(0.5)">{word}</g>\n</svg>\n'
    )


if __name__ == "__main__":
    for name, size, small in FILES:
        render(size, small).save(ICONS / name, optimize=True)
    (IMAGES / "vedivox-header-dark.svg").write_text(header_svg(PAPER))
    (IMAGES / "vedivox-header-light.svg").write_text(header_svg(FG_LIGHT))
    (IMAGES / "vedivox-wordmark-dark.svg").write_text(wordmark_svg(PAPER))
    (IMAGES / "vedivox-wordmark-light.svg").write_text(wordmark_svg(FG_LIGHT))
