#!/usr/bin/env python3
"""Render the Talkra app icon and menu bar template icon from one geometric design.

The mark is a selection pill holding a voice waveform, crossed by a text I-beam. Outputs:
  Sources/OpenClip/Assets.xcassets/AppIcon.appiconset/AppIcon-{16..1024}.png
  Sources/OpenClip/Assets.xcassets/MenuBarIcon.imageset/MenuBarIcon-{18,36,54}.png
  assets/app-icon.{png,svg}, assets/menubar-icon.{png,svg}

Usage: python3 scripts/generate_icons.py   (needs Pillow)
"""
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "Sources/OpenClip/Assets.xcassets"
SS = 4  # supersampling factor

PILL_TOP = (112, 92, 255)   # #705CFF
PILL_BOTTOM = (62, 58, 228)  # #3E3AE4
BODY_FILL = (239, 239, 241)
INK = (45, 45, 47)

# Design space is 1024x1024 (Apple's macOS icon grid: 824pt body inset 100pt).
# A selection pill holding a waveform, crossed by a text I-beam cursor.
BODY = (100, 100, 924, 924, 186)
PILL = (190, 340, 700, 684, 120)
WAVE_HEIGHTS = [70, 150, 220, 150, 70]
WAVE_WIDTH = 36
WAVE_GAP = 30
WAVE_CX = 440
WAVE_CY = 512
BEAM_CX = 640
BEAM_STEM = (BEAM_CX - 32, 250, BEAM_CX + 32, 774)
BEAM_CAPS = [(BEAM_CX - 126, 212, BEAM_CX + 126, 296), (BEAM_CX - 126, 728, BEAM_CX + 126, 812)]
BEAM_RADIUS = 34


def wave_bars(cx=WAVE_CX, width=WAVE_WIDTH, gap=WAVE_GAP, heights=WAVE_HEIGHTS):
    total = len(heights) * width + (len(heights) - 1) * gap
    x = cx - total / 2
    out = []
    for h in heights:
        out.append((x, WAVE_CY - h / 2, x + width, WAVE_CY + h / 2))
        x += width + gap
    return out


def vertical_gradient(size, top, bottom):
    w, h = size
    grad = Image.new("RGBA", (1, h))
    for y in range(h):
        t = y / max(1, h - 1)
        grad.putpixel((0, y), tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)) + (255,))
    return grad.resize((w, h))


def s(v):
    return v * SS


def beam_rects():
    return [BEAM_STEM] + BEAM_CAPS


def render_app_icon():
    size = 1024 * SS
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(canvas)
    x0, y0, x1, y1, r = BODY
    d.rounded_rectangle((s(x0), s(y0), s(x1), s(y1)), radius=s(r), fill=BODY_FILL + (255,))

    px0, py0, px1, py1, pr = PILL
    pill_mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(pill_mask).rounded_rectangle((s(px0), s(py0), s(px1), s(py1)), radius=s(pr), fill=255)
    pill = vertical_gradient((size, size), PILL_TOP, PILL_BOTTOM)
    canvas.paste(pill, (0, 0), pill_mask)

    d = ImageDraw.Draw(canvas)
    for bx0, by0, bx1, by1 in wave_bars():
        d.rounded_rectangle((s(bx0), s(by0), s(bx1), s(by1)), radius=s(WAVE_WIDTH / 2), fill=(255, 255, 255, 255))
    for bx0, by0, bx1, by1 in beam_rects():
        d.rounded_rectangle((s(bx0), s(by0), s(bx1), s(by1)), radius=s(BEAM_RADIUS), fill=INK + (255,))

    return canvas.resize((1024, 1024), Image.LANCZOS)


MENU_BARS = dict(cx=WAVE_CX, width=44, gap=36, heights=[90, 190, 90])


def render_menubar_icon(px):
    """Template image: black pill with the waveform knocked out, plus the I-beam, fitted to the canvas."""
    size = 1024 * SS
    mask = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(mask)
    left, right, top, bottom = 190, 766, 212, 812
    k = 1024 * 0.9 / max(right - left, bottom - top)
    ox = 512 - k * (left + right) / 2
    oy = 512 - k * (top + bottom) / 2

    def t(x, y):
        return s(x * k + ox), s(y * k + oy)

    px0, py0, px1, py1, pr = PILL
    d.rounded_rectangle((*t(px0, py0), *t(px1, py1)), radius=s(pr * k), fill=255)
    for bx0, by0, bx1, by1 in wave_bars(**MENU_BARS):
        d.rounded_rectangle((*t(bx0, by0), *t(bx1, by1)), radius=s(MENU_BARS["width"] * k / 2), fill=0)
    for bx0, by0, bx1, by1 in beam_rects():
        # Gap around the I-beam keeps it readable where it crosses the pill.
        d.rounded_rectangle((*t(bx0 - 14, by0 - 14), *t(bx1 + 14, by1 + 14)), radius=s((BEAM_RADIUS + 14) * k), fill=0)
    for bx0, by0, bx1, by1 in beam_rects():
        d.rounded_rectangle((*t(bx0, by0), *t(bx1, by1)), radius=s(BEAM_RADIUS * k), fill=255)
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    img.paste((0, 0, 0, 255), (0, 0), mask)
    return img.resize((px, px), Image.LANCZOS)


def rects_svg(rects, rx, fill, indent="  "):
    return "\n".join(
        f'{indent}<rect x="{x0:g}" y="{y0:g}" width="{x1 - x0:g}" height="{y1 - y0:g}" rx="{rx:g}" fill="{fill}"/>'
        for x0, y0, x1, y1 in rects
    )


def app_icon_svg():
    x0, y0, x1, y1, r = BODY
    px0, py0, px1, py1, pr = PILL
    return f"""<svg width="1024" height="1024" viewBox="0 0 1024 1024" fill="none" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <linearGradient id="pill" x1="0" y1="{py0}" x2="0" y2="{py1}" gradientUnits="userSpaceOnUse">
      <stop stop-color="#705CFF"/><stop offset="1" stop-color="#3E3AE4"/>
    </linearGradient>
  </defs>
  <rect x="{x0}" y="{y0}" width="{x1 - x0}" height="{y1 - y0}" rx="{r}" fill="#EFEFF1"/>
  <rect x="{px0}" y="{py0}" width="{px1 - px0}" height="{py1 - py0}" rx="{pr}" fill="url(#pill)"/>
{rects_svg(wave_bars(), WAVE_WIDTH / 2, "white")}
{rects_svg(beam_rects(), BEAM_RADIUS, "#2D2D2F")}
</svg>
"""


def menubar_svg():
    px0, py0, px1, py1, pr = PILL
    gap = 14
    halo = [(a - gap, b - gap, c + gap, d + gap) for a, b, c, d in beam_rects()]
    return f"""<svg width="1024" height="1024" viewBox="150 172 656 680" xmlns="http://www.w3.org/2000/svg">
  <mask id="cut">
    <rect x="0" y="0" width="1024" height="1024" fill="white"/>
{rects_svg(wave_bars(**MENU_BARS), MENU_BARS["width"] / 2, "black", "    ")}
{rects_svg(halo, BEAM_RADIUS + gap, "black", "    ")}
  </mask>
  <rect x="{px0}" y="{py0}" width="{px1 - px0}" height="{py1 - py0}" rx="{pr}" fill="black" mask="url(#cut)"/>
{rects_svg(beam_rects(), BEAM_RADIUS, "black")}
</svg>
"""


def main():
    icon = render_app_icon()
    appiconset = ASSETS / "AppIcon.appiconset"
    for px in (16, 32, 64, 128, 256, 512, 1024):
        icon.resize((px, px), Image.LANCZOS).save(appiconset / f"AppIcon-{px}.png")
    icon.save(ROOT / "assets/app-icon.png")
    (ROOT / "assets/app-icon.svg").write_text(app_icon_svg())

    menubar = ASSETS / "MenuBarIcon.imageset"
    for px in (18, 36, 54):
        render_menubar_icon(px).save(menubar / f"MenuBarIcon-{px}.png")
    render_menubar_icon(512).save(ROOT / "assets/menubar-icon.png")
    (ROOT / "assets/menubar-icon.svg").write_text(menubar_svg())


if __name__ == "__main__":
    main()
