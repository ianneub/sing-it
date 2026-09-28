"""hymnpdf: convert an engraved hymn PDF into the app's hymn JSON.

    python -m hymnpdf HYMN.pdf -o HYMN.json [--midi out.mid [--full-form]] [--overlay prefix] [--dump]
"""

from __future__ import annotations

import argparse
import json
import sys

from .extract import PART_ORDER, NoMusicError, extract
from .midi import write_midi
from .overlay import write_overlay


def _note(n: dict) -> str:
    """G4/1, r/1 for a rest; ^ fermata, [G2] alternative pitch, ?v2 sung only in verse 2."""
    text = f"{n.get('pitch', 'r')}/{n['duration']:g}"
    text += "^" if n.get("fermata") else ""
    text += "".join(f"[{a['pitch']}]" for a in n.get("alt", []))
    text += f"?v{','.join(map(str, n['verses']))}" if "verses" in n else ""
    return text


def dump(score: dict) -> str:
    """Measure-by-measure listing of every part plus the lyrics, for reading against the page."""
    out = [f"{score['number']}  {score['title']}   key fifths={score['key']['fifths']} {score['key']['mode']}  "
           f"time {score['time']['beats']}/{score['time']['beatType']}  tempo {score['tempo']}"]
    if "timeChanges" in score:
        out.append("time changes: " + ", ".join(f"{c['beats']}/{c['beatType']}@{c['start']:g}" for c in score["timeChanges"]))
    if "voicing" in score:
        out.append("voicing: " + ", ".join(f"{v['voicing']}@{v['start']:g}" for v in score["voicing"]))
    for m in score["measures"]:
        a, b = m["start"], m["start"] + m["duration"]
        out.append(f"-- m{m['number']} beats {a:g}-{b:g}")
        for part in PART_ORDER:
            notes = [n for n in score["parts"][part] if a <= n["start"] < b]
            out.append(f"   {part[0].upper()}: " + "  ".join(_note(n) for n in notes))
    for i, s in enumerate(score["sections"]):
        out.append(f"== section {i} {s['kind']} beats {s['start']:g}-{s['end']:g}")
        for line in s["lyrics"]:
            text = " ".join(f"{x['text']}{'-' if x['syllabic'] in ('begin', 'middle') else ''}@{x['start']:g}"
                            for x in line["syllables"])
            tag = f" {'+'.join(line['parts'])} {line['start']:g}-{line['end']:g}" if "parts" in line else ""
            tag += " (approximate)" if line.get("approximate") else ""
            out.append(f"   v{line['verse']}{tag}: {text}")
    out.append(f"intro: {score['intro']}")
    out.append(f"credits: {score['credits']}")
    for w in score["warnings"]:
        out.append(f"WARNING: {w}")
    return "\n".join(out)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="hymnpdf", description=__doc__.splitlines()[0])
    ap.add_argument("pdf")
    ap.add_argument("-o", "--output", help="write hymn JSON here")
    ap.add_argument("--number", type=int, help="hymn number, if the PDF doesn't print one")
    ap.add_argument("--midi", help="write a MIDI file for listening checks")
    ap.add_argument("--full-form", action="store_true", help="MIDI plays every verse with its chorus")
    ap.add_argument("--overlay", help="write PNGs of the pages with extracted notes drawn on (path prefix)")
    ap.add_argument("--dump", action="store_true", help="print a measure-by-measure listing")
    ap.add_argument("--strict", action="store_true", help="exit non-zero if there are warnings")
    args = ap.parse_args(argv)

    try:
        score = extract(args.pdf, args.number)
    except NoMusicError as e:  # e.g. a licensing notice printed instead of the music
        print(f"hymnpdf: nothing to convert, {e}", file=sys.stderr)
        return 0
    if args.output:
        with open(args.output, "w") as f:
            json.dump(score, f, indent=1, ensure_ascii=False)
            f.write("\n")
    if args.midi:
        write_midi(score, args.midi, full_form=args.full_form)
    if args.overlay:
        for p in write_overlay(score, args.pdf, args.overlay):
            print(f"overlay: {p}", file=sys.stderr)
    if args.dump:
        print(dump(score))
    for w in score["warnings"]:
        print(f"warning: {w}", file=sys.stderr)
    return 1 if args.strict and score["warnings"] else 0


if __name__ == "__main__":
    sys.exit(main())
