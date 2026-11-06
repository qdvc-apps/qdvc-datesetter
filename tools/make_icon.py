#!/usr/bin/env python3
"""Generate the app icon: Resources/AppIcon.svg (vector master) and
Resources/AppIcon.icns (every macOS size, rendered natively from the vector).

The design is kept simple: a fanned stack of three photo prints (white
borders, each a small landscape: dawn hills, a sunny sea, dusk mountains),
sealed with a glossy teal badge carrying a white clock whose arrow runs
backwards (anticlockwise): turning back the photos' dates. It is drawn in the
macOS 26 Liquid Glass style, in a "Dusk" palette (pale lilac to slate
violet), and follows the icons of QDVC Progress, Response Letter, Meetings,
Nice Mail, Bibliotheca and GTD EML for macOS, so the apps look like a family.

Geometry follows Apple's macOS icon template: a 1024x1024 canvas holding an
824x824 tile (100 px transparent margin) with a 185.4 px continuous-curvature
("squircle") corner, plus a soft drop shadow. The corner is the curve UIKit
draws for continuous corners, as reverse-engineered and published by PaintCode
(paintcodeapp.com, "Code for iOS 7 rounded rectangles").

Usage:

    python3 tools/make_icon.py            # writes Resources/AppIcon.{svg,icns}
    python3 tools/make_icon.py --preview  # also writes build/icon-preview.png

Requires rsvg-convert (macOS: `brew install librsvg`; Debian/Ubuntu:
`apt install librsvg2-bin`). No other dependencies; the .icns is written
directly, so Apple's iconutil is not needed.
"""

import argparse
import math
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "Resources"

# ---------------------------------------------------------------------------
# Palette ("Dusk"). The deep tone also tints the shadows, so the white prints
# stay distinct from the pale background.

BG_TOP = "#F4F1FA"
BG_DEEP = "#6E6496"

# The seal: a teal sphere with a white clock and a backwards arrow.
FACE_LIGHT, FACE_MID, FACE_DARK = "#7FE0D2", "#1E9C8C", "#0B4F48"
FEATURES = "#FFFFFF"

# The three photos, back to front: (centre x, centre y, rotation in degrees,
# scene). Each scene is (sky top, sky bottom, sun, far hills, near hills).
PHOTOS = [
    (430, 452, -15, ("#F7B267", "#F4845F", "#FFE8A3", "#B5547A", "#7D3C6B")),   # dusk mountains
    (560, 438, 11, ("#6EC6F5", "#CDEBFA", "#FFF4B8", "#2F86C9", "#1E5E99")),    # sunny sea
    (486, 520, -3, ("#9AD3F2", "#E7F5FC", "#FFD866", "#7CC26E", "#3E8E4F")),    # green hills
]
PHOTO_W, PHOTO_H = 392, 312
BORDER, BORDER_BOTTOM = 20, 56
SEAL_CENTRE, SEAL_RADIUS = (722, 724), 132

# ---------------------------------------------------------------------------
# Apple's template geometry.

TILE_ORIGIN, TILE_SIZE, CORNER_RADIUS = 100, 824, 185.4
SHADOW_BLUR_RADIUS, SHADOW_OFFSET_Y, SHADOW_OPACITY = 28, 12, 0.5

# Continuous-corner segments around the top-right corner, in units of the
# radius: (distance from the right edge, distance from the top edge).
_CORNER = [
    ("L", (1.52866471, 0.0)),
    ("C", (1.08849323, 0.0), (0.86840689, 0.0), (0.66993427, 0.06549600)),
    ("L", (0.63149399, 0.07491100)),
    ("C", (0.37282392, 0.16905899), (0.16906013, 0.37282401), (0.07491176, 0.63149399)),
    ("C", (0.0, 0.86840701), (0.0, 1.08849299), (0.0, 1.52866483)),
]


def continuous_rounded_rect(x, y, w, h, r):
    """SVG path of a rounded rectangle with Apple's continuous corners."""
    r = min(r, min(w, h) / 2 / 1.52866483)
    corners = [
        lambda u, v: (x + w - u * r, y + v * r),        # top-right
        lambda u, v: (x + w - v * r, y + h - u * r),    # bottom-right
        lambda u, v: (x + u * r, y + h - v * r),        # bottom-left
        lambda u, v: (x + v * r, y + u * r),            # top-left
    ]

    def fmt(p):
        return f"{p[0]:.2f},{p[1]:.2f}"

    d = [f"M{fmt((x + 1.52866483 * r, y))}"]
    for corner in corners:
        for seg in _CORNER:
            if seg[0] == "L":
                d.append("L" + fmt(corner(*seg[1])))
            else:
                d.append("C" + " ".join(fmt(corner(*p)) for p in seg[1:]))
    d.append("Z")
    return " ".join(d)


TILE = continuous_rounded_rect(TILE_ORIGIN, TILE_ORIGIN, TILE_SIZE, TILE_SIZE, CORNER_RADIUS)


def _photo(index, cx, cy, angle, scene):
    """One print: a white card with a landscape inset, rotated about its centre.
    Returns (defs, elements)."""
    sky_top, sky_bottom, sun, far, near = scene
    x0, y0 = cx - PHOTO_W / 2, cy - PHOTO_H / 2
    ix, iy = x0 + BORDER, y0 + BORDER
    iw, ih = PHOTO_W - 2 * BORDER, PHOTO_H - BORDER - BORDER_BOTTOM
    defs = [
        f'<linearGradient id="sky{index}" x1="0" y1="0" x2="0" y2="1">'
        f'<stop offset="0" stop-color="{sky_top}"/><stop offset="1" stop-color="{sky_bottom}"/></linearGradient>',
        f'<clipPath id="pic{index}"><rect x="{ix:.1f}" y="{iy:.1f}" width="{iw:.1f}" height="{ih:.1f}" rx="10"/></clipPath>',
    ]

    def pt(fx, fy):
        return f"{ix + fx * iw:.1f},{iy + fy * ih:.1f}"

    far_hills = f'M{pt(0, 0.62)} L{pt(0.22, 0.38)} L{pt(0.42, 0.58)} L{pt(0.66, 0.30)} L{pt(1, 0.60)} L{pt(1, 1)} L{pt(0, 1)} Z'
    near_hills = (f'M{pt(0, 0.80)} C{pt(0.25, 0.58)} {pt(0.45, 0.62)} {pt(0.62, 0.76)} '
                  f'C{pt(0.78, 0.88)} {pt(0.90, 0.70)} {pt(1, 0.72)} L{pt(1, 1)} L{pt(0, 1)} Z')
    sun_x, sun_y = ix + 0.76 * iw, iy + 0.26 * ih
    parts = [
        f'<g transform="rotate({angle} {cx} {cy})">',
        f'<rect x="{x0:.1f}" y="{y0:.1f}" width="{PHOTO_W}" height="{PHOTO_H}" rx="18" fill="url(#paper)"/>',
        f'<g clip-path="url(#pic{index})">',
        f'<rect x="{ix:.1f}" y="{iy:.1f}" width="{iw:.1f}" height="{ih:.1f}" fill="url(#sky{index})"/>',
        f'<circle cx="{sun_x:.1f}" cy="{sun_y:.1f}" r="{ih * 0.14:.1f}" fill="{sun}"/>',
        f'<path d="{far_hills}" fill="{far}"/>',
        f'<path d="{near_hills}" fill="{near}"/>',
        '</g>',
        f'<rect x="{x0 + 1.5:.1f}" y="{y0 + 1.5:.1f}" width="{PHOTO_W - 3}" height="{PHOTO_H - 3}" rx="17" '
        'fill="none" stroke="url(#rim)" stroke-width="3"/>',
        '</g>',
    ]
    return defs, parts


def _seal(cx, cy, r):
    """A glossy teal seal in a white ring, with a white clock face drawn as
    two hands and an arrow running anticlockwise around them."""
    ring = r * 0.64
    width = r * 0.13

    def at(deg, radius=ring):
        a = math.radians(deg)
        return cx + radius * math.cos(a), cy + radius * math.sin(a)

    # SVG angles: 0 deg points right and angles grow clockwise (y is down).
    # The arc starts at the left, below a gap at the upper left, and runs
    # anticlockwise (decreasing angle) through the bottom, the right and the
    # top, ending at the upper left, where the arrowhead points on,
    # anticlockwise, into the gap.
    start, end = 188.0, -122.0
    sx, sy = at(start)
    ex, ey = at(end)
    arc = (f'M{sx:.1f},{sy:.1f} A{ring:.1f},{ring:.1f} 0 1 0 {ex:.1f},{ey:.1f}')
    # Direction of travel at the end (decreasing angle): (sin a, -cos a).
    a = math.radians(end)
    dx, dy = math.sin(a), -math.cos(a)
    nx, ny = -dy, dx
    head = r * 0.30
    tip = (ex + dx * head * 0.75, ey + dy * head * 0.75)
    back = (ex - dx * head * 0.35, ey - dy * head * 0.35)
    left = (back[0] + nx * head * 0.62, back[1] + ny * head * 0.62)
    right = (back[0] - nx * head * 0.62, back[1] - ny * head * 0.62)
    arrow = (f'M{tip[0]:.1f},{tip[1]:.1f} L{left[0]:.1f},{left[1]:.1f} '
             f'L{right[0]:.1f},{right[1]:.1f} Z')
    # Hands: minute hand to 12, hour hand to 2, clear of the arrowhead.
    hx, hy = at(-30, r * 0.30)
    mx, my = at(-90, r * 0.42)
    return [
        f'<circle cx="{cx}" cy="{cy}" r="{r + 11}" fill="#FFFFFF" opacity="0.92"/>',
        f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="url(#face)"/>',
        f'<path d="{arc}" fill="none" stroke="{FEATURES}" stroke-width="{width:.1f}" stroke-linecap="round"/>',
        f'<path d="{arrow}" fill="{FEATURES}" stroke="{FEATURES}" stroke-width="{r * 0.05:.1f}" stroke-linejoin="round"/>',
        f'<line x1="{cx}" y1="{cy}" x2="{hx:.1f}" y2="{hy:.1f}" stroke="{FEATURES}" stroke-width="{width:.1f}" stroke-linecap="round"/>',
        f'<line x1="{cx}" y1="{cy}" x2="{mx:.1f}" y2="{my:.1f}" stroke="{FEATURES}" stroke-width="{width * 0.8:.1f}" stroke-linecap="round"/>',
        f'<circle cx="{cx}" cy="{cy}" r="{width * 0.75:.1f}" fill="{FEATURES}"/>',
        # specular highlight
        f'<ellipse cx="{cx - r * 0.30:.1f}" cy="{cy - r * 0.58:.1f}" rx="{r * 0.36:.1f}" '
        f'ry="{r * 0.16:.1f}" fill="#FFFFFF" opacity="0.38"/>',
    ]


def _hex2rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def _mix(a, b, t):
    ra, rb = _hex2rgb(a), _hex2rgb(b)
    return "#%02X%02X%02X" % tuple(round(x + (y - x) * t) for x, y in zip(ra, rb))


def icon_svg():
    sigma = SHADOW_BLUR_RADIUS / 2
    defs = [
        f'<linearGradient id="bg" x1="0" y1="0" x2="0.35" y2="1">'
        f'<stop offset="0" stop-color="{BG_TOP}"/><stop offset="1" stop-color="{BG_DEEP}"/></linearGradient>',
        '<radialGradient id="glow" cx="0.30" cy="0.18" r="0.75">'
        '<stop offset="0" stop-color="#FFFFFF" stop-opacity="0.34"/>'
        '<stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/></radialGradient>',
        '<linearGradient id="sheen" x1="0" y1="0" x2="0" y2="1">'
        '<stop offset="0" stop-color="#FFFFFF" stop-opacity="0.22"/>'
        '<stop offset="0.40" stop-color="#FFFFFF" stop-opacity="0.03"/>'
        '<stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/></linearGradient>',
        '<linearGradient id="rim" x1="0" y1="0" x2="0" y2="1">'
        '<stop offset="0" stop-color="#FFFFFF" stop-opacity="0.9"/>'
        '<stop offset="0.5" stop-color="#FFFFFF" stop-opacity="0.3"/>'
        '<stop offset="1" stop-color="#FFFFFF" stop-opacity="0.6"/></linearGradient>',
        '<linearGradient id="edge" x1="0" y1="0" x2="0" y2="1">'
        '<stop offset="0" stop-color="#FFFFFF" stop-opacity="0.75"/>'
        '<stop offset="0.5" stop-color="#FFFFFF" stop-opacity="0.12"/>'
        '<stop offset="1" stop-color="#FFFFFF" stop-opacity="0.35"/></linearGradient>',
        # Photo paper: white, frosted slightly toward the bottom.
        '<linearGradient id="paper" x1="0" y1="0" x2="0" y2="1">'
        '<stop offset="0" stop-color="#FFFFFF" stop-opacity="0.97"/>'
        f'<stop offset="1" stop-color="{_mix("#FFFFFF", BG_DEEP, 0.12)}" stop-opacity="0.93"/></linearGradient>',
        '<radialGradient id="face" cx="0.38" cy="0.30" r="0.8">'
        f'<stop offset="0" stop-color="{FACE_LIGHT}"/><stop offset="0.55" stop-color="{FACE_MID}"/>'
        f'<stop offset="1" stop-color="{FACE_DARK}"/></radialGradient>',
        f'<clipPath id="clip"><path d="{TILE}"/></clipPath>',
        # Apple template shadow: black, 28 px blur radius, 12 px down, 50 %.
        '<filter id="shadow" x="-20%" y="-20%" width="140%" height="140%">'
        f'<feGaussianBlur in="SourceAlpha" stdDeviation="{sigma}"/><feOffset dy="{SHADOW_OFFSET_Y}"/>'
        f'<feComponentTransfer><feFuncA type="linear" slope="{SHADOW_OPACITY}"/></feComponentTransfer>'
        '<feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge></filter>',
        # Tinted shadow under each print and the seal.
        '<filter id="objshadow" x="-30%" y="-30%" width="160%" height="160%">'
        '<feGaussianBlur in="SourceAlpha" stdDeviation="13"/><feOffset dx="0" dy="14"/>'
        f'<feFlood flood-color="{BG_DEEP}" flood-opacity="0.55"/><feComposite operator="in" in2="SourceAlpha"/>'
        '<feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge></filter>',
    ]
    objects = []
    for i, (cx, cy, angle, scene) in enumerate(PHOTOS):
        photo_defs, parts = _photo(i, cx, cy, angle, scene)
        defs += photo_defs
        objects += ['<g filter="url(#objshadow)">', *parts, '</g>']
    objects += ['<g filter="url(#objshadow)">', *_seal(*SEAL_CENTRE, SEAL_RADIUS), '</g>']
    parts = [
        f'<g filter="url(#shadow)"><path d="{TILE}" fill="url(#bg)"/></g>',
        '<g clip-path="url(#clip)">',
        '<rect x="100" y="100" width="824" height="824" fill="url(#glow)"/>',
        *objects,
        '<rect x="100" y="100" width="824" height="824" fill="url(#sheen)"/>',
        '</g>',
        f'<path d="{TILE}" fill="none" stroke="url(#edge)" stroke-width="6"/>',
    ]
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
            f'<defs>{"".join(defs)}</defs>{"".join(parts)}</svg>\n')


# ---------------------------------------------------------------------------
# .icns writing. These are the element types `iconutil` emits for a standard
# .iconset; all of them hold PNG data.

ICNS_ELEMENTS = [
    ("icp4", 16), ("ic11", 32), ("icp5", 32), ("ic12", 64),
    ("ic07", 128), ("ic13", 256), ("ic08", 256), ("ic14", 512),
    ("ic09", 512), ("ic10", 1024),
]


def render_png(svg_path, size, out_path):
    subprocess.run(["rsvg-convert", "-w", str(size), "-h", str(size), str(svg_path), "-o", str(out_path)],
                   check=True)


def write_icns(pngs_by_size, out_path):
    chunks = b""
    for code, size in ICNS_ELEMENTS:
        data = pngs_by_size[size]
        chunks += code.encode("ascii") + struct.pack(">I", len(data) + 8) + data
    out_path.write_bytes(b"icns" + struct.pack(">I", len(chunks) + 8) + chunks)


def main():
    parser = argparse.ArgumentParser(description="Generate Resources/AppIcon.svg and AppIcon.icns.")
    parser.add_argument("--preview", action="store_true",
                        help="also write build/icon-preview.png (1024 px)")
    args = parser.parse_args()

    try:
        subprocess.run(["rsvg-convert", "--version"], check=True, capture_output=True)
    except (OSError, subprocess.CalledProcessError):
        sys.exit("error: rsvg-convert not found (macOS: brew install librsvg)")

    RESOURCES.mkdir(exist_ok=True)
    svg_path = RESOURCES / "AppIcon.svg"
    svg_path.write_text(icon_svg())

    with tempfile.TemporaryDirectory() as tmp:
        pngs = {}
        for size in sorted({s for _, s in ICNS_ELEMENTS}):
            png = Path(tmp) / f"icon_{size}.png"
            render_png(svg_path, size, png)
            pngs[size] = png.read_bytes()
        write_icns(pngs, RESOURCES / "AppIcon.icns")

    if args.preview:
        (ROOT / "build").mkdir(exist_ok=True)
        render_png(svg_path, 1024, ROOT / "build" / "icon-preview.png")
    print(f"Wrote {svg_path.relative_to(ROOT)} and Resources/AppIcon.icns")


if __name__ == "__main__":
    main()
