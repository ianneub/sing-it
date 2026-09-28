"""Draw the extracted notes back onto the PDF pages, for checking extraction by eye."""

from __future__ import annotations

import pymupdf

COLORS = {"soprano": (0.85, 0.1, 0.1), "alto": (0.95, 0.55, 0.0), "tenor": (0.1, 0.35, 0.9), "bass": (0.0, 0.6, 0.2)}
# Labels sit above the head for upper parts and below it for lower parts.
LABEL_DY = {"soprano": -6, "alto": 9, "tenor": -6, "bass": 9}


def write_overlay(score: dict, pdf_path: str, out_prefix: str, zoom: float = 3.0) -> list[str]:
    doc = pymupdf.open(pdf_path)
    for part, notes in score["parts"].items():
        color = COLORS[part]
        for n in notes:
            for i, h in enumerate(n["heads"]):
                page = doc[h["page"] - 1]
                page.draw_circle((h["x"], h["y"]), 3.2, color=color, width=0.8)
                if i == 0:
                    label = f"{n.get('pitch', 'rest')} {n['duration']:g}"
                    page.insert_text((h["x"] - 6, h["y"] + LABEL_DY[part]), label, fontsize=3.2, color=color)
    paths = []
    for i, page in enumerate(doc):
        path = f"{out_prefix}-{i + 1}.png"
        page.get_pixmap(matrix=pymupdf.Matrix(zoom, zoom)).save(path)
        paths.append(path)
    return paths
