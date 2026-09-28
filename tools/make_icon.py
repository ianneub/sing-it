"""Draw the app icon (1024x1024 PNG): a white note on a blue gradient, with a green trail of
sung pitches rising into the notehead.

    .venv/bin/python tools/make_icon.py   ->  ios/SingIt/Assets.xcassets/AppIcon.appiconset/AppIcon.png
"""

import math
from pathlib import Path

import pymupdf

SIZE = 1024
ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "ios/SingIt/Assets.xcassets/AppIcon.appiconset/AppIcon.png"


def rgb(hex_colour):
    return tuple(int(hex_colour[i:i + 2], 16) / 255 for i in (1, 3, 5))


def main():
    doc = pymupdf.open()
    page = doc.new_page(width=SIZE, height=SIZE)

    # Background: a vertical gradient, deep blue to indigo (iOS rounds the corners).
    top, bottom = rgb("#1B2F7A"), rgb("#5B3FD9")
    strips = 256
    for i in range(strips):
        t = i / (strips - 1)
        colour = tuple(a + (b - a) * t for a, b in zip(top, bottom))
        y0 = SIZE * i / strips
        page.draw_rect(pymupdf.Rect(0, y0, SIZE, y0 + SIZE / strips + 1), color=None, fill=colour)

    white = (1, 1, 1)
    # The note: a tilted oval head, a stem and a flag.
    head_centre = pymupdf.Point(560, 700)
    rx, ry, tilt = 132, 96, -22
    points = []
    for k in range(72):
        a = 2 * math.pi * k / 72
        x, y = rx * math.cos(a), ry * math.sin(a)
        c, s = math.cos(math.radians(tilt)), math.sin(math.radians(tilt))
        points.append(pymupdf.Point(head_centre.x + x * c - y * s, head_centre.y + x * s + y * c))
    shape = page.new_shape()
    shape.draw_polyline(points + [points[0]])
    shape.finish(color=None, fill=white, closePath=True)
    stem_x = head_centre.x + 112
    shape.draw_rect(pymupdf.Rect(stem_x, 190, stem_x + 46, 660))
    shape.finish(color=None, fill=white)
    # Flag: a curved sweep from the top of the stem.
    shape.draw_bezier(pymupdf.Point(stem_x + 40, 190), pymupdf.Point(stem_x + 60, 330),
                      pymupdf.Point(stem_x + 250, 330), pymupdf.Point(stem_x + 200, 560))
    shape.draw_bezier(pymupdf.Point(stem_x + 200, 560), pymupdf.Point(stem_x + 190, 440),
                      pymupdf.Point(stem_x + 100, 380), pymupdf.Point(stem_x + 40, 380))
    shape.finish(color=None, fill=white, closePath=True)
    shape.commit()

    # The sung pitch: dots rising and settling into the notehead, green like "in tune".
    green = rgb("#34D17A")
    trail = [(150, 860, 16), (225, 830, 20), (300, 805, 25), (370, 775, 30), (435, 742, 36)]
    for x, y, r in trail:
        page.draw_circle(pymupdf.Point(x, y), r, color=None, fill=green)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    page.get_pixmap(alpha=False).save(str(OUT))
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
