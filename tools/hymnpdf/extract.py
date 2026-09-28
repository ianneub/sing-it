"""Turn an engraved hymn PDF from ChurchOfJesusChrist.org into a structured score.

The Church's hymn PDFs are vector engravings, not scans:
  * noteheads, clefs, accidentals, dots, flags and time-signature digits are
    glyphs in the Maestro music font;
  * staff lines, stems, barlines, beams, ties and slurs are vector paths;
  * lyrics, title, tempo and credits are real text.
So nothing here is OCR: every value comes from exact coordinates. Coordinates
are PDF points with y growing downward. A Maestro notehead's origin y is the
vertical centre of the head.

Hymns are printed in close score: soprano + alto on the treble staff, tenor +
bass on the bass staff. On each staff:
  * two parts moving together share one stem (top head = upper part);
  * parts with different rhythms get separate stems (up = upper, down = lower);
  * a unison is drawn as two identical, overlapping noteheads;
  * a rest on the middle line is for both parts, one moved up or down for one part;
  * cue-size (small) notes are optional: an alternative pitch, or a note that only
    some verses sing, printed over a rest.
Italic labels ("Unison", "Duet", "Harmony") change which printed notes are sung.

Two PDF producers made these files. InDesign PDFs map every glyph to Unicode.
Ghostscript/TeX PDFs leave the half notehead and the fi/fl ligatures unmapped (PyMuPDF
then reports a control character), so those are identified from the fonts themselves,
and they draw flat beams as filled rectangles rather than polygons.
"""

from __future__ import annotations

import hashlib
import itertools
import re
import struct
import unicodedata
from dataclasses import dataclass, field, replace
from fractions import Fraction

import pymupdf

from .syllables import align_words, fit_words

HEAD_BEATS = {"œ": 1.0, "˙": 2.0, "w": 4.0}  # notehead glyph -> base length in quarter notes
REST_BEATS = {"Ó": 2.0, "Œ": 1.0, "‰": 0.5, "≈": 0.25}  # rest glyph -> length in quarter notes
ACCIDENTALS = {"b": -1, "n": 0, "#": 1}
FLAGS = {"j", "J"}  # eighth-note flag, stem up / stem down
FERMATAS = {"U": "above", "u": "below"}  # fermata over the staff below it / under the staff above it
PARENS = {"(", ")"}  # around optional (cue-size) notes, which are recognised by their size
# Italic performance labels at the start of a passage. In a unison passage everyone sings the
# melody (the treble staff's upper part) and the other printed notes are accompaniment; in a
# duet the treble staff's two parts are sung over a bass-staff accompaniment. The men sing
# the melody an octave lower in both.
VOICINGS = {"Unison": "unison", "Harmony": "harmony", "Duet": "duet"}
TEMPO_UNITS = {"q": "quarter", "h": "half", "e": "eighth"}  # EngraverTextT note symbols in the tempo mark
DOT = "."
TREBLE, BASS = "&", "?"
# Diatonic index (C0 = 0, D0 = 1, ...) of each clef's bottom staff line: E4, G2.
BOTTOM_LINE = {TREBLE: 4 * 7 + 2, BASS: 2 * 7 + 4}
STEP_NAMES = "CDEFGAB"
STEP_SEMITONES = [0, 2, 4, 5, 7, 9, 11]
SHARP_ORDER = "FCGDAEB"
MAJOR_TONIC_BY_FIFTHS = {f: n for f, n in zip(range(-7, 8), "Cb Gb Db Ab Eb Bb F C G D A E B F# C#".split())}
PARTS = {TREBLE: ("soprano", "alto"), BASS: ("tenor", "bass")}  # (upper, lower)
PART_ORDER = ["soprano", "alto", "tenor", "bass"]

STEM_MAX_WIDTH = 0.4  # stems are 0.34pt, barlines 0.459pt
CUE_STEM_WIDTH = 0.3  # cue-size notes have thinner stems (0.255pt)
CUE_SIZE = 3.4  # a notehead engraved below this many staff spaces (normally 4) is cue-size
STEM_HEAD_INSET = 0.17  # stem centre sits this far inside the head's edge


class ExtractionError(Exception):
    pass


class NoMusicError(ExtractionError):
    """The PDF prints no music, only a notice (e.g. that licensing prevents publishing it)."""


# --- raw page contents -------------------------------------------------------


@dataclass
class Glyph:
    char: str
    x0: float
    x1: float
    y: float
    page: int
    size: float = 0.0  # font size; cue (small) notes are engraved at 3/4 size

    @property
    def cx(self) -> float:
        return (self.x0 + self.x1) / 2


@dataclass
class Token:
    text: str
    x0: float
    x1: float
    y: float  # baseline
    size: float
    italic: bool
    page: int

    @property
    def cx(self) -> float:
        return (self.x0 + self.x1) / 2


@dataclass
class VLine:
    x: float
    y0: float
    y1: float
    width: float
    page: int


@dataclass
class Beam:
    """A filled beam: a parallelogram with vertical ends (a plain rectangle when horizontal)."""

    x0: float
    x1: float
    left: tuple[float, float]  # (top, bottom) y at x0
    right: tuple[float, float]  # (top, bottom) y at x1

    def centre(self, x: float) -> float:
        x = min(max(x, self.x0), self.x1)
        f = (x - self.x0) / (self.x1 - self.x0) if self.x1 > self.x0 else 0.0
        return (sum(self.left) + f * (sum(self.right) - sum(self.left))) / 2


@dataclass
class Page:
    number: int  # 1-based
    width: float
    height: float
    glyphs: list[Glyph]
    brackets: list[Glyph]
    tokens: list[Token]
    hlines: list[tuple[float, float, float]]  # (x0, x1, y)
    vlines: list[VLine]
    curves: list[pymupdf.Rect]
    beams: list[Beam]
    tempo_glyphs: list[Glyph] = field(default_factory=list)  # EngraverTextT note symbols (q, h, e)


# --- fonts without a Unicode mapping --------------------------------------------

# Maestro outlines that some PDFs embed with no Unicode mapping, keyed by the md5 of the
# glyph's TrueType glyf record (first 8 hex digits).
KNOWN_MAESTRO_OUTLINES = {"3da2f0c6": "˙"}
LIGATURES = {"ff", "fi", "fl", "ffi", "ffl"}


def _truetype_outlines(buf: bytes) -> dict[int, str]:
    """Glyph id -> short hash of its outline, for every non-empty glyph of a TrueType font."""
    tables = {}
    for i in range(struct.unpack(">H", buf[4:6])[0]):
        tag, _, offset, length = struct.unpack(">4sIII", buf[12 + 16 * i:28 + 16 * i])
        tables[tag] = buf[offset:offset + length]
    loca, glyf = tables[b"loca"], tables[b"glyf"]
    if struct.unpack(">h", tables[b"head"][50:52])[0] == 0:
        offsets = [2 * v for v in struct.unpack(f">{len(loca) // 2}H", loca)]
    else:
        offsets = list(struct.unpack(f">{len(loca) // 4}I", loca))
    return {gid: hashlib.md5(glyf[a:b]).hexdigest()[:8] for gid, (a, b) in enumerate(zip(offsets, offsets[1:])) if b > a}


def unmapped_maestro_glyphs(doc: pymupdf.Document) -> dict[str, str]:
    """Maestro glyphs that have no Unicode in the PDF: {character PyMuPDF reports: Maestro char}.

    Every one of these engravings puts the half notehead alone in a Type0 (CID) subset of
    Maestro. InDesign gives that font a ToUnicode map ('˙'); Ghostscript doesn't, and PyMuPDF
    then reports the raw CID as the character: a control code that differs from file to file.
    The CID is the glyph id, so the glyph is identified by its outline.
    """
    found: dict[str, str] = {}
    for page in doc:
        for xref, _, ftype, base, _, _ in page.get_fonts():
            if ftype != "Type0" or "Maestro" not in base or doc.xref_get_key(xref, "ToUnicode")[0] != "null":
                continue
            try:
                outlines = _truetype_outlines(doc.extract_font(xref)[3])
            except (struct.error, KeyError):
                continue
            for gid, h in outlines.items():
                if h in KNOWN_MAESTRO_OUTLINES:
                    found[chr(gid)] = KNOWN_MAESTRO_OUTLINES[h]
    return found


def _glyph_name_text(name: str) -> str | None:
    base = name.split(".")[0]  # "fi.liga" -> "fi"
    if base in LIGATURES:
        return base
    if base in ("nbspace", "space"):
        return "\xa0" if base == "nbspace" else " "
    m = re.fullmatch(r"uni([0-9A-F]{4})", base)
    return chr(int(m.group(1), 16)) if m else None


def unmapped_text_codes(doc: pymupdf.Document) -> dict[str, dict[str, str]]:
    """{font name: {character PyMuPDF reports: text}} for low character codes of text fonts.

    The Ghostscript PDFs put the fi/fl ligatures at codes below 0x20 via the font's
    /Encoding /Differences, under names ("fi.liga") that aren't in the Adobe Glyph List, so the
    PDF has no Unicode for them and PyMuPDF reports the raw code. The code assignment varies
    from file to file, so read it from the font's own glyph names.
    """
    out: dict[str, dict[str, str]] = {}
    conflicts: set[tuple[str, str]] = set()
    for page in doc:
        for xref, _, ftype, base, _, _ in page.get_fonts():
            if ftype not in ("Type1", "TrueType", "Type1C", "MMType1"):
                continue
            kind, enc = doc.xref_get_key(xref, "Encoding")
            if kind == "xref":
                enc = doc.xref_object(int(enc.split()[0]))
            m = re.search(r"/Differences\s*\[(.*?)\]", enc, re.S)
            if not m:
                continue
            name, code = base.split("+")[-1], 0
            for tok in re.findall(r"\d+|/[^\s/\[\]]+", m.group(1)):
                if tok[0] != "/":
                    code = int(tok)
                    continue
                text = _glyph_name_text(tok[1:])
                if code < 0x20 and text is not None:
                    table = out.setdefault(name, {})
                    if table.get(chr(code), text) != text:
                        conflicts.add((name, chr(code)))
                    table[chr(code)] = text
                code += 1
    for name, ch in conflicts:
        del out[name][ch]
    return out


def _split_tokens(chars, size, italic, page) -> list[Token]:
    """Split a span's characters into words, keeping hyphens as their own tokens."""
    tokens, cur = [], []

    def flush():
        if cur:
            tokens.append(
                Token(unicodedata.normalize("NFKC", "".join(c["c"] for c in cur)), cur[0]["bbox"][0], cur[-1]["bbox"][2],
                      cur[0]["origin"][1], size, italic, page)
            )
            cur.clear()

    for ch in chars:
        # Only real spaces separate words: str.isspace() is also true for the control codes
        # that stand for unmapped ligatures.
        if unicodedata.category(ch["c"][0]) == "Zs":
            flush()
        elif ch["c"] == "-":
            flush()
            cur.append(ch)
            flush()
        else:
            cur.append(ch)
    flush()
    return tokens


def _beam(d: dict) -> Beam | None:
    """A filled path is a beam if it is a rectangle or a parallelogram with vertical ends whose
    thickness is about half a staff space. InDesign draws every beam as a filled polygon;
    Ghostscript draws horizontal beams as rectangles ('re')."""
    if d.get("fill") is None:
        return None
    kinds = {it[0] for it in d["items"]}
    if kinds == {"re"} and len(d["items"]) == 1:
        r = d["items"][0][1]
        pts = [r.tl, r.tr, r.br, r.bl]
    elif kinds == {"l"} and len(d["items"]) >= 3:
        pts = [p for it in d["items"] for p in it[1:3]]
    else:
        return None
    x0, x1 = min(p.x for p in pts), max(p.x for p in pts)
    left = [p.y for p in pts if abs(p.x - x0) < 0.3]
    right = [p.y for p in pts if abs(p.x - x1) < 0.3]
    thickness = (max(left) - min(left), max(right) - min(right))
    if x1 - x0 < 2 or not all(1.2 < t < 3.2 for t in thickness):
        return None
    return Beam(x0, x1, (min(left), max(left)), (min(right), max(right)))


def read_page(page: pymupdf.Page, number: int, maestro_map: dict[str, str] | None = None,
              text_map: dict[str, dict[str, str]] | None = None) -> Page:
    maestro_map, text_map = maestro_map or {}, text_map or {}
    glyphs, brackets, tokens, tempo_glyphs = [], [], [], []
    for block in page.get_text("rawdict")["blocks"]:
        for line in block.get("lines", []):
            for span in line["spans"]:
                font, chars, size = span["font"], span["chars"], span["size"]
                if "Maestro" in font:
                    # A control character here is an unmapped glyph, not whitespace.
                    glyphs += [Glyph(maestro_map.get(c["c"], c["c"]), c["bbox"][0], c["bbox"][2], c["origin"][1],
                                     number, size)
                               for c in chars if c["c"] != " "]
                elif "DingPI" in font:  # ⌜ ⌝ introduction brackets
                    brackets += [Glyph(c["c"], c["bbox"][0], c["bbox"][2], c["origin"][1], number, size)
                                 for c in chars if not c["c"].isspace()]
                elif "Engraver" in font:  # the note symbol in the tempo mark
                    tempo_glyphs += [Glyph(c["c"], c["bbox"][0], c["bbox"][2], c["origin"][1], number, size)
                                     for c in chars if not c["c"].isspace()]
                else:
                    codes = text_map.get(font, {})
                    chars = [dict(c, c=codes.get(c["c"], c["c"])) for c in chars]
                    tokens += _split_tokens(chars, size, bool(span["flags"] & pymupdf.TEXT_FONT_ITALIC), number)

    hlines, vlines, curves, beams = [], [], [], []
    for d in page.get_drawings():
        kinds = {it[0] for it in d["items"]}
        if "c" in kinds:
            curves.append(d["rect"])
            continue
        beam = _beam(d)
        if beam is not None:
            beams.append(beam)
            continue
        if d.get("fill") is not None and kinds == {"l"} and len(d["items"]) >= 3:
            continue  # some other filled shape
        for it in d["items"]:
            if it[0] != "l":
                continue
            p, q = it[1], it[2]
            if abs(p.y - q.y) < 0.1:
                hlines.append((min(p.x, q.x), max(p.x, q.x), p.y))
            elif abs(p.x - q.x) < 0.1:
                vlines.append(VLine(p.x, min(p.y, q.y), max(p.y, q.y), d.get("width") or 0.0, number))

    return Page(number, page.rect.width, page.rect.height, glyphs, brackets, tokens,
                hlines, vlines, curves, beams, tempo_glyphs)


# --- staves and systems ------------------------------------------------------


@dataclass(eq=False)
class Staff:
    page: int
    lines: list[float]
    x0: float
    x1: float
    clef: str = ""

    @property
    def top(self) -> float:
        return self.lines[0]

    @property
    def bottom(self) -> float:
        return self.lines[-1]

    @property
    def spacing(self) -> float:
        return (self.bottom - self.top) / 4

    def distance(self, y: float) -> float:
        if self.top <= y <= self.bottom:
            return 0.0
        return min(abs(y - self.top), abs(y - self.bottom))

    def diatonic(self, y: float) -> int:
        return BOTTOM_LINE[self.clef] + round((self.bottom - y) / (self.spacing / 2))


@dataclass(eq=False)
class System:
    index: int  # 0-based across the whole hymn
    page: int
    treble: Staff
    bass: Staff
    barlines: list[float] = field(default_factory=list)
    lyric_lines: list[list[Token]] = field(default_factory=list)  # rows sung by every part
    part_lines: list[list[Token]] = field(default_factory=list)  # rows sung only by the bass staff's parts
    carry: list[list[Token]] = field(default_factory=list)  # row ends that belong to the next section
    carry_x: float = 0.0  # the barline where the next section starts

    @property
    def staves(self) -> tuple[Staff, Staff]:
        return (self.treble, self.bass)


def find_staves(page: Page) -> list[Staff]:
    long_lines = sorted((l for l in page.hlines if l[1] - l[0] > page.width / 2), key=lambda l: l[2])
    staves, group = [], []
    for line in long_lines:
        if group and (line[2] - group[-1][2] > 6 or len(group) == 5):
            staves.append(group)
            group = []
        group.append(line)
    if group:
        staves.append(group)
    result = []
    for g in staves:
        if len(g) != 5:
            raise ExtractionError(f"page {page.number}: staff with {len(g)} lines at y={g[0][2]:.1f}")
        result.append(Staff(page.number, [l[2] for l in g], g[0][0], g[0][1]))
    return result


def build_systems(pages: list[Page]) -> list[System]:
    systems = []
    for page in pages:
        staves = find_staves(page)
        for staff in staves:
            for g in page.glyphs:
                if g.char in (TREBLE, BASS) and staff.distance(g.y) < staff.spacing * 2 and g.x0 < staff.x0 + 20:
                    staff.clef = g.char
        if len(staves) % 2 or any(s.clef != (TREBLE if i % 2 == 0 else BASS) for i, s in enumerate(staves)):
            raise ExtractionError(f"page {page.number}: expected treble/bass staff pairs, got "
                                  f"{[s.clef or '?' for s in staves]}")
        for i in range(0, len(staves), 2):
            systems.append(System(len(systems), page.number, staves[i], staves[i + 1]))
    return systems


def nearest_staff(systems: list[System], page: int, y: float) -> tuple[System, Staff]:
    candidates = [(st.distance(y), sys, st) for sys in systems if sys.page == page for st in sys.staves]
    _, sys, st = min(candidates, key=lambda c: c[0])
    return sys, st


# --- noteheads and chords ----------------------------------------------------


@dataclass(eq=False)
class Head:
    """A notehead, or a rest (which is timed like a note but has no pitch)."""

    glyph: Glyph
    system: System
    staff: Staff
    dotted: bool = False
    accidental: int | None = None
    octave: int = 0  # sung this many octaves from where it is printed (men singing the melody)

    @property
    def rest(self) -> bool:
        return self.glyph.char in REST_BEATS

    @property
    def cue(self) -> bool:
        """Cue-size (small) notes are optional: an alternative pitch (e.g. a low octave for the
        basses) or a note sung in only some verses, printed over a rest."""
        return not self.rest and self.glyph.size < CUE_SIZE * self.staff.spacing

    @property
    def x(self) -> float:
        return self.glyph.x0

    @property
    def cx(self) -> float:
        return self.glyph.cx

    @property
    def y(self) -> float:
        return self.glyph.y


@dataclass(eq=False)
class Chord:
    """Noteheads sounding together with one rhythm: those on one stem, or one stemless head."""

    heads: list[Head]
    stem: VLine | None
    up: bool | None
    beams: int = 0

    @property
    def duration(self) -> float:
        char = self.heads[0].glyph.char
        beats = REST_BEATS[char] if char in REST_BEATS else HEAD_BEATS[char] / (2 ** self.beams)
        return beats * 1.5 if any(h.dotted for h in self.heads) else beats


def _heads_on_stem(stem: VLine, heads: list[Head]) -> list[Head]:
    """Noteheads belonging to a stem.

    A head normally sits left of an up-stem and right of a down-stem. It sits on the
    other side only when it is a second away from a normal head on the same stem.
    Otherwise it is another part's note that happens to touch the stem, e.g. a tenor
    half note beside a bass quarter note on the same pitch.
    """
    near = [h for h in heads if stem.y0 - 1.5 <= h.y <= stem.y1 + 1.5]
    left = [h for h in near if abs(stem.x - (h.glyph.x1 - STEM_HEAD_INSET)) < 0.7]
    right = [h for h in near if abs(stem.x - (h.glyph.x0 + STEM_HEAD_INSET)) < 0.7]
    if not left and not right:
        return []
    ys = [h.y for h in left + right]
    up = abs(stem.y1 - max(ys)) < abs(stem.y0 - min(ys))
    normal, other = (left, right) if up else (right, left)
    if not normal:
        return []
    step = normal[0].staff.spacing / 2
    displaced = [h for h in other
                 if any(abs(abs(h.y - n.y) - step) < 0.5 for n in normal)]
    return normal + displaced


def build_chords(page: Page, systems: list[System], warnings: list[str]) -> tuple[list[Chord], list[Head]]:
    heads: list[Head] = []
    for g in page.glyphs:
        if g.char not in HEAD_BEATS:
            continue
        # A unison is two identical overlapping glyphs; keep one head, it gets both stems.
        if any(h.glyph.char == g.char and abs(h.x - g.x0) < 0.3 and abs(h.y - g.y) < 0.3 for h in heads):
            continue
        sys, st = nearest_staff(systems, page.number, g.y)
        heads.append(Head(g, sys, st))
    rests = [Head(g, *nearest_staff(systems, page.number, g.y)) for g in page.glyphs if g.char in REST_BEATS]

    _attach_dots_and_accidentals(page, systems, heads + rests, warnings)

    chords, stemmed = [], set()
    for stem in page.vlines:
        if stem.width >= STEM_MAX_WIDTH or stem.y1 - stem.y0 < 6:
            continue
        # Cue-size heads have their own thinner stems.
        attached = _heads_on_stem(stem, [h for h in heads if h.cue == (stem.width < CUE_STEM_WIDTH)])
        if not attached:
            continue
        if len({id(h.staff) for h in attached}) > 1:
            warnings.append(f"page {page.number}: stem at x={stem.x:.1f} touches heads on two staves")
        top, bottom = min(h.y for h in attached), max(h.y for h in attached)
        up = abs(stem.y1 - bottom) < abs(stem.y0 - top)
        chords.append(Chord(sorted(attached, key=lambda h: h.y), stem, up))
        stemmed.update(id(h) for h in attached)
    for h in heads:
        if id(h) not in stemmed:
            chords.append(Chord([h], None, None))
    chords += [Chord([r], None, None) for r in rests]

    for g in page.glyphs:
        if g.char in FLAGS:
            chord = _chord_at_stem(chords, g.x0, g.y, slack=4)
            if chord is None:
                warnings.append(f"page {page.number}: flag at ({g.x0:.1f},{g.y:.1f}) has no stem")
            else:
                chord.beams += 1
    # A stem gets one beam level for every beam it crosses between its free end and its heads:
    # the primary beam at the free end, then secondary (16th) beams and partial-beam stubs
    # stacked one beam-spacing further in.
    for chord in chords:
        s = chord.stem
        if s is None:
            continue
        top, bottom = chord.heads[0].y, chord.heads[-1].y
        for beam in page.beams:
            if not beam.x0 - 0.6 <= s.x <= beam.x1 + 0.6:
                continue
            y = beam.centre(s.x)
            if s.y0 - 1 <= y <= s.y1 + 1 and (y < top - 2 if chord.up else y > bottom + 2):
                chord.beams += 1
    return chords, heads


def _chord_at_stem(chords: list[Chord], x: float, y: float, slack: float) -> Chord | None:
    for chord in chords:
        s = chord.stem
        if s is not None and abs(s.x - x) < 1.0 and s.y0 - slack <= y <= s.y1 + slack:
            return chord
    return None


def _attach_dots_and_accidentals(page, systems, heads, warnings):
    for g in page.glyphs:
        if g.char == DOT:
            _, st = nearest_staff(systems, page.number, g.y)
            best = min(
                ((g.x0 - h.glyph.x1 + abs(g.y - h.y), h) for h in heads
                 if h.staff is st and 0 <= g.x0 - h.glyph.x1 < 8 and abs(g.y - h.y) < st.spacing * 0.6),
                key=lambda c: c[0], default=None)
            if best is None:
                warnings.append(f"page {page.number}: dot at ({g.x0:.1f},{g.y:.1f}) matches no notehead")
            else:
                best[1].dotted = True
        elif g.char in ACCIDENTALS:
            _, st = nearest_staff(systems, page.number, g.y)
            target = [h for h in heads if h.staff is st and not h.rest and 0 < h.x - g.x1 < 10 and abs(h.y - g.y) < 0.8]
            if target:
                target[0].accidental = ACCIDENTALS[g.char]
            # otherwise it belongs to a key signature, read separately


# --- key and time signatures --------------------------------------------------


def read_key_signature(page: Page, staff: Staff, first_head_x: float) -> int:
    """Return the key as a count of fifths (flats negative)."""
    accs = [g for g in page.glyphs
            if g.char in ("b", "#") and staff.distance(g.y) < staff.spacing * 2 and g.x1 < first_head_x
            and g.x0 > staff.x0 + 10]
    if not accs:
        return 0
    if len({g.char for g in accs}) > 1:
        raise ExtractionError("mixed sharps and flats in key signature")
    return len(accs) * (-1 if accs[0].char == "b" else 1)


def key_alteration(fifths: int, step: int) -> int:
    name = STEP_NAMES[step]
    if fifths > 0:
        return 1 if name in SHARP_ORDER[:fifths] else 0
    if fifths < 0:
        return -1 if name in SHARP_ORDER[::-1][:-fifths] else 0
    return 0


def read_time_signatures(page: Page, staff: Staff) -> list[tuple[float, int, int]]:
    """Every time signature printed on a staff, as (x, beats, beat type), left to right.

    A signature is two numbers stacked in one column, above and below the middle line.
    A hymn may change meter anywhere, and print a courtesy signature at the end of a system.
    """
    digits = [g for g in page.glyphs if g.char.isdigit() and staff.distance(g.y) < staff.spacing * 2]
    rows = []
    for above in (True, False):
        numbers: list[list[Glyph]] = []
        for g in sorted((g for g in digits if (g.y < staff.lines[2]) == above), key=lambda g: g.x0):
            if numbers and g.x0 - numbers[-1][-1].x1 < 1.0:  # multi-digit number, e.g. 12
                numbers[-1].append(g)
            else:
                numbers.append([g])
        rows.append([((n[0].x0 + n[-1].x1) / 2, n[0].x0, int("".join(g.char for g in n))) for n in numbers])
    top, bottom = rows
    sigs = []
    for cx, x0, beats in top:
        below = [b for b in bottom if abs(b[0] - cx) < 3]
        if len(below) != 1:
            raise ExtractionError(f"page {page.number}: time signature at x={x0:.1f} has no single lower number")
        sigs.append((min(x0, below[0][1]), beats, below[0][2]))
    if len(sigs) != len(bottom):
        raise ExtractionError(f"page {page.number}: could not pair time signature digits {[g.char for g in digits]}")
    return sigs


# --- voices, timing, pitch ---------------------------------------------------


@dataclass(eq=False)
class Note:
    part: str
    heads: list[Head]  # more than one when tied
    duration: float
    diatonic: int
    alter: int
    start: float = 0.0
    measure: int = 0
    rest: bool = False
    fermata: bool = False
    alts: list[Note] = field(default_factory=list)  # cue-size alternative pitches (e.g. an optional low octave)
    optional: bool = False  # a cue note printed over a rest: sung only in the verses that have a syllable on it
    verses: list[int] = field(default_factory=list)  # for an optional note, the verses that sing it

    @property
    def midi(self) -> int:
        octave, step = divmod(self.diatonic, 7)
        return 12 * (octave + 1) + STEP_SEMITONES[step] + self.alter

    @property
    def name(self) -> str:
        octave, step = divmod(self.diatonic, 7)
        return STEP_NAMES[step] + {-1: "b", 0: "", 1: "#"}[self.alter] + str(octave)

    @property
    def head(self) -> Head:
        return self.heads[0]


def _chord_parts(chord: Chord) -> list[tuple[str, Head]]:
    upper, lower = PARTS[chord.heads[0].staff.clef]
    if len(chord.heads) >= 2:
        return [(upper, chord.heads[0]), (lower, chord.heads[-1])]
    if chord.up is True:
        return [(upper, chord.heads[0])]
    if chord.up is False:
        return [(lower, chord.heads[0])]
    return [(upper, chord.heads[0]), (lower, chord.heads[0])]  # stemless single head, e.g. a whole-note unison


def _rest_parts(rest: Head, chords: list[Chord]) -> list[str]:
    """The parts a rest is for: those of its staff with no note printed in its column. When
    neither has a note there, a rest on the middle line (or moved aside for cue notes) is for
    both parts, and one displaced up or down is for the upper or lower part only (the other
    part is holding a note)."""
    upper, lower = PARTS[rest.staff.clef]
    column = [c for c in chords if c.heads[0].staff is rest.staff and not c.heads[0].rest
              and abs(c.heads[0].cx - rest.cx) < 3]
    normal = [c for c in column if not c.heads[0].cue]
    if normal:
        covered = {p for c in normal for p, _ in _chord_parts(c)}
        return [p for p in (upper, lower) if p not in covered]
    offset = (rest.y - rest.staff.lines[2]) / rest.staff.spacing
    if abs(offset) <= 0.75 or column:
        return [upper, lower]
    return [upper] if offset < 0 else [lower]


def read_voicings(pages: list[Page], systems: list[System], warnings: list[str]) -> list[tuple[int, float, str]]:
    """Performance labels ("Unison", "Harmony", "Duet") printed in italics under a treble staff
    at the start of a passage, as (system index, x, voicing). Each lasts until the next."""
    out = []
    for sys in systems:
        for t in pages[sys.page - 1].tokens:
            if t.italic and sys.treble.bottom < t.y < sys.bass.top and t.x0 < sys.treble.x0 + 60:
                if t.text in VOICINGS:
                    out.append((sys.index, t.x0, VOICINGS[t.text]))
                elif re.fullmatch(r"Women|Men|Solo|Descant", t.text):
                    warnings.append(f"system {sys.index}: voicing label '{t.text}' is not handled")
    return sorted(out)


def voicing_at(voicings: list[tuple[int, float, str]], head: Head) -> str | None:
    now = [v for s, x, v in voicings if (s, x) <= (head.system.index, head.x)]
    return now[-1] if now else None


def assign_parts(chords: list[Chord], voicings, warnings: list[str]) -> tuple[dict[str, list[tuple[Head, float]]],
                                                                              list[tuple[str, Head, float]]]:
    """Split chords into the four parts' (head, duration) streams. Cue-size notes are returned
    separately as (part, head, duration); they don't take time of their own.

    In unison and duet passages only the treble staff is sung (its upper part only, for
    unison); the soprano's notes are copied an octave lower for the men (and as they are for
    the alto, in unison).
    """
    parts: dict[str, list[tuple[Head, float]]] = {p: [] for p in PART_ORDER}
    cues: list[tuple[str, Head, float]] = []
    sung = {"unison": {"soprano"}, "duet": {"soprano", "alto"}}
    for chord in chords:
        voicing = voicing_at(voicings, chord.heads[0])
        allowed = sung.get(voicing, set(PART_ORDER))
        if chord.heads[0].rest:
            for part in _rest_parts(chord.heads[0], chords):
                if part in allowed:
                    parts[part].append((chord.heads[0], chord.duration))
            if voicing in sung and chord.heads[0].staff.clef == TREBLE and "soprano" in _rest_parts(chord.heads[0], chords):
                for part in PART_ORDER[1:]:
                    if part not in allowed:
                        parts[part].append((chord.heads[0], chord.duration))
            continue
        if voicing in sung:
            for part, head in _chord_parts(chord):
                if part in allowed and not head.cue:
                    parts[part].append((head, chord.duration))
                if part == "soprano" and not head.cue:
                    for other in PART_ORDER[1:]:
                        if other not in allowed:
                            parts[other].append((replace(head, octave=0 if other == "alto" else -1), chord.duration))
            continue
        if len(chord.heads) > 2:
            h = chord.heads[0]
            warnings.append(f"page {h.glyph.page}: {len(chord.heads)} heads on one stem at x={h.x:.1f}")
        for part, head in _chord_parts(chord):
            if head.cue:
                cues.append((part, head, chord.duration))
            else:
                parts[part].append((head, chord.duration))
    return parts, cues


def apply_tuplets(pages: list[Page], systems: list[System], parts, warnings: list[str]) -> None:
    """Scale the notes under a tuplet number (e.g. a triplet's small italic '3', printed as
    text over the staff) so n of them fill the time of the next lower power of two.

    For each part on that staff, the tuplet is the run of consecutive notes centred under the
    number whose written lengths add up to n of its shortest note (three eighths, or a
    quarter and an eighth).
    """
    for page in pages:
        for tok in page.tokens:
            if not (tok.italic and re.fullmatch(r"[3-7]", tok.text) and tok.size < 9):
                continue
            if not any(sys.page == page.number for sys in systems):
                continue
            sys, st = nearest_staff(systems, page.number, tok.y)
            if st.distance(tok.y) > 3 * st.spacing:
                continue
            n = int(tok.text)
            scale = 2 ** (n.bit_length() - 1) / n
            if n & (n - 1) == 0:
                continue
            matched = False
            for part in PART_ORDER:  # usually the staff's two parts; all four in a unison passage
                entries = sorted((e for e in parts[part] if e[0].system is sys and e[0].staff is st), key=lambda e: e[0].x)
                best = None
                for i in range(len(entries)):
                    for j in range(i + 1, len(entries)):
                        run = entries[i:j + 1]
                        unit = min(d for _, d in run)
                        off = abs((run[0][0].cx + run[-1][0].cx) / 2 - tok.cx)
                        if off < 5 and abs(sum(d for _, d in run) - n * unit) < 1e-6 and (best is None or off < best[0]):
                            best = (off, run)
                if best:
                    matched = True
                    for e in best[1]:
                        k = next(k for k, x in enumerate(parts[part]) if x is e)
                        parts[part][k] = (e[0], e[1] * scale)
            if not matched:
                warnings.append(f"page {page.number}: tuplet {n} at x={tok.x0:.1f} is over no group of notes")


def lay_out_time(parts, systems, fifths, signatures, warnings) -> tuple[dict[str, list[Note]], list[dict], list[dict]]:
    """Give every note a start time and pitch; return the notes, the measure list and the
    time signatures in force ({start, beats, beatType}, the first at 0).

    Measures end only at barlines: a measure may continue across a system break
    (hymnals split measures at the end of a phrase). `signatures` lists (system, x, beats,
    beat type) as printed; each takes effect at the first note or rest to its right. One
    with nothing after it in its system is a courtesy signature for the next system.

    Time is summed exactly (a triplet's thirds add up to whole beats), so parts, measures and
    lyrics that meet after a tuplet get identical start times.
    """
    notes: dict[str, list[Note]] = {}
    bar_times: dict[str, list[float]] = {}
    for part, entries in parts.items():
        entries.sort(key=lambda e: (e[0].system.index, e[0].x))
        seq: list[Note] = []
        bars: list[float] = []
        t = Fraction(0)
        accidentals: dict[int, int] = {}
        i = 0
        for sys in systems:
            barlines = sorted(sys.barlines)
            sys_entries = [e for e in entries if e[0].system is sys]
            for head, dur in sys_entries:
                while barlines and barlines[0] < head.x:
                    bars.append(float(t))
                    accidentals.clear()
                    barlines.pop(0)
                if head.rest:
                    seq.append(Note(part, [head], dur, 0, 0, start=float(t), rest=True))
                    t += Fraction(dur).limit_denominator(96)
                    continue
                d = head.staff.diatonic(head.y) + 7 * head.octave
                if head.accidental is not None:
                    accidentals[d] = head.accidental
                alter = accidentals.get(d, key_alteration(fifths, d % 7))
                seq.append(Note(part, [head], dur, d, alter, start=float(t)))
                t += Fraction(dur).limit_denominator(96)
                i += 1
            for _ in barlines:  # barline after the last note of the system
                bars.append(float(t))
                accidentals.clear()
        notes[part] = seq
        bar_times[part] = bars

    ref = bar_times["soprano"]
    for part in PART_ORDER[1:]:
        if len(bar_times[part]) != len(ref) or any(abs(a - b) > 1e-6 for a, b in zip(bar_times[part], ref)):
            mismatch = next((k for k, (a, b) in enumerate(zip(bar_times[part], ref)) if abs(a - b) > 1e-6), None)
            warnings.append(f"{part} disagrees with soprano at barline {mismatch}: "
                            f"{part} {bar_times[part][mismatch] if mismatch is not None else '?'} vs "
                            f"soprano {ref[mismatch] if mismatch is not None else '?'} beats")
    end = max(seq[-1].start + seq[-1].duration for seq in notes.values() if seq)
    for part, seq in notes.items():
        if seq and abs(seq[-1].start + seq[-1].duration - end) > 1e-6:
            warnings.append(f"{part} ends at {seq[-1].start + seq[-1].duration} beats, others at {end}")

    meters: list[dict] = []
    for sys, x, beats, beat_type in signatures:
        after = [n.start for seq in notes.values() for n in seq if n.head.system is sys and n.head.x > x]
        if not after:
            continue  # courtesy signature
        if not meters or (meters[-1]["beats"], meters[-1]["beatType"]) != (beats, beat_type):
            meters.append({"start": min(after) if meters else 0.0, "beats": beats, "beatType": beat_type})

    def measure_len(t: float) -> float:
        m = [m for m in meters if m["start"] <= t + 1e-6][-1]
        return m["beats"] * 4 / m["beatType"]

    boundaries = [0.0] + [b for b in ref if 0 < b < end] + [end]
    measures = []
    for k, (a, b) in enumerate(zip(boundaries, boundaries[1:])):
        measures.append({"start": a, "duration": b - a})
        full = abs(b - a - measure_len(a)) < 1e-6
        first_or_last = k == 0 or k == len(boundaries) - 2
        if not full and not first_or_last:
            warnings.append(f"measure starting at beat {a} lasts {b - a} beats, expected {measure_len(a)}")
    for m in meters[1:]:
        if not any(abs(b - m["start"]) < 1e-6 for b in boundaries):
            warnings.append(f"time signature {m['beats']}/{m['beatType']} at beat {m['start']} is not at a barline")
    # Number measures as printed: a short first measure is a pickup, numbered 0.
    first = 0 if measures and measures[0]["duration"] < measure_len(0) - 1e-6 else 1
    for k, m in enumerate(measures):
        m["number"] = first + k
    for seq in notes.values():
        for n in seq:
            n.measure = next(m["number"] for m in reversed(measures) if m["start"] <= n.start + 1e-6)
    return notes, measures, meters


def place_cues(cues, notes: dict[str, list[Note]], fifths: int, warnings: list[str]) -> None:
    """Attach cue-size notes to the part's printed note or rest in the same column.

    Over a note, a cue head is an alternative pitch (`alts`). Over a rest (e.g. a note in
    parentheses that only one verse's words need), it replaces the rest as an optional note.
    """
    for part, head, dur in cues:
        target = next((n for n in notes[part] if n.head.system is head.system and abs(n.head.cx - head.cx) < 3), None)
        d = head.staff.diatonic(head.y)
        alter = head.accidental if head.accidental is not None else (
            target.alter if target is not None and not target.rest and target.diatonic % 7 == d % 7
            else key_alteration(fifths, d % 7))
        cue = Note(part, [head], dur, d, alter)
        if target is None:
            warnings.append(f"page {head.glyph.page}: cue note at x={head.x:.1f} has no {part} note or rest under it")
        elif target.rest:
            if abs(target.duration - dur) > 1e-6:
                warnings.append(f"page {head.glyph.page}: cue note at x={head.x:.1f} is {dur:g} beats over a "
                                f"{target.duration:g}-beat {part} rest")
            cue.start, cue.measure, cue.optional = target.start, target.measure, True
            notes[part][notes[part].index(target)] = cue
        else:
            target.alts.append(cue)


def apply_ties(page_curves, systems, notes, warnings) -> None:
    """Merge tied notes. A curve joining two consecutive same-pitch notes of one part is a tie;
    joining different pitches it is a slur, which matters only for lyrics and is ignored.

    A tie printed for one verse is merged for all: a verse whose words have a syllable
    starting inside the merged note sings the same pitch again there (the lyrics timeline
    shows it).
    """
    for page_number, curves in page_curves:
        for curve in curves:
            sys, st = nearest_staff(systems, page_number, (curve.y0 + curve.y1) / 2)
            best = None
            for part in PART_ORDER:  # usually the staff's two parts; all four in a unison passage
                seq = notes[part]
                for a, b in zip(seq, seq[1:]):
                    ha, hb = a.heads[-1], b.head
                    if ha.staff is not st or hb.staff is not st or a.rest or b.rest:
                        continue
                    if curve.x0 - 10 < ha.cx < curve.x0 + 3 and curve.x1 - 3 < hb.cx < curve.x1 + 10:
                        dist = min(min(abs(curve.y0 - h.y), abs(curve.y1 - h.y)) for h in (ha, hb))
                        if best is None or dist < best[0] - 0.5:
                            best = (dist, [(part, a, b)])
                        elif abs(dist - best[0]) <= 0.5:
                            best[1].append((part, a, b))
            if best is None:
                if curve.x1 > st.x1 - 4 or curve.x0 < st.x0 + 40:
                    warnings.append(f"page {page_number}: curve at x={curve.x0:.1f}-{curve.x1:.1f} may be a "
                                    "tie across a system break (not handled)")
                continue
            for part, a, b in best[1]:
                if a.rest or b.rest or a.midi != b.midi or b not in notes[part]:
                    continue
                a.duration += b.duration
                a.heads += b.heads
                notes[part].remove(b)


def apply_fermatas(pages: list[Page], systems: list[System], notes: dict[str, list[Note]], warnings) -> None:
    """A fermata ('U' over a staff, 'u' under it) holds every note or rest of that staff whose
    head is centred under it. Timing is unchanged; the singers just hold."""
    for page in pages:
        for g in page.glyphs:
            if g.char not in FERMATAS:
                continue
            staves = [st for sys in systems if sys.page == page.number for st in sys.staves
                      if (st.top > g.y if FERMATAS[g.char] == "above" else st.bottom < g.y)]
            if not staves:
                warnings.append(f"page {page.number}: fermata at ({g.x0:.1f},{g.y:.1f}) has no staff")
                continue
            st = min(staves, key=lambda st: st.distance(g.y))
            held = [n for seq in notes.values() for n in seq if any(h.staff is st and abs(h.cx - g.cx) < 3 for h in n.heads)]
            if not held:  # the staff is accompaniment here (a unison passage): hold what is sung in that column
                sys = next(sys for sys in systems if st in sys.staves)
                held = [n for seq in notes.values() for n in seq
                        if any(h.system is sys and abs(h.cx - g.cx) < 3 for h in n.heads)]
            if not held:
                warnings.append(f"page {page.number}: fermata at ({g.x0:.1f},{g.y:.1f}) is over no note")
            for n in held:
                n.fermata = True


# --- lyrics -------------------------------------------------------------------


def read_lyrics(pages: list[Page], systems: list[System]) -> None:
    for sys in systems:
        page = pages[sys.page - 1]
        words = [t for t in page.tokens
                 if not t.italic and sys.treble.bottom + 2 < t.y < sys.bass.top - 2
                 and t.x0 > sys.treble.x0]
        rows: list[list[Token]] = []
        for t in sorted(words, key=lambda t: t.y):
            if rows and abs(rows[-1][0].y - t.y) < 2:
                rows[-1].append(t)
            else:
                rows.append([t])
        sys.lyric_lines = [sorted(r, key=lambda t: t.x0) for r in rows]


HYPHENS = ("-", "–")  # between the syllables of a word
WORD_SPACE = 3.0  # points; the lyric font's space is about 2


def _is_dash(text: str) -> bool:
    """A token made only of dashes (an em dash standing alone) is punctuation, not a syllable."""
    return bool(re.fullmatch(r"[—―_]+", text))


@dataclass
class Syllable:
    text: str
    start: float
    hyphen_after: bool = False
    syllabic: str = "single"


def time_columns(sys: System, notes: dict[str, list[Note]], rests: bool = False) -> list[tuple[float, float, float, int]]:
    """(x centre, start beat, end beat, part rank) of every notehead in the system, and of every
    rest if asked. Call before ties are merged."""
    return [(n.head.cx, n.start, n.start + n.duration, PART_ORDER.index(part))
            for part, seq in notes.items() for n in seq if n.head.system is sys and (rests or not n.rest)]


def check_columns(notes: dict[str, list[Note]], warnings: list[str]) -> None:
    """Heads printed in one column sound together. Parts that disagree about a column's time
    have a misread rhythm, even if their totals happen to agree at the barlines."""
    heads = sorted(((n.head.system.index, n.head.cx, n.start, part) for part, seq in notes.items() for n in seq
                    if not n.rest), key=lambda h: h[:2])
    for a, b in zip(heads, heads[1:]):
        if a[0] == b[0] and abs(a[1] - b[1]) < 0.5 and abs(a[2] - b[2]) > 1e-6:
            warnings.append(f"system {a[0]} x={a[1]:.1f}: {a[3]} starts at {a[2]:g} but {b[3]} at {b[2]:g}")


def syllables_for_line(tokens: list[Token], cols, warnings, where: str) -> tuple[int | None, list[Syllable]]:
    verse = None
    out: list[Syllable] = []
    for i, tok in enumerate(tokens):
        if i == 0 and re.fullmatch(r"\d+\.", tok.text):
            verse = int(tok.text[:-1])
            continue
        if tok.text in HYPHENS:
            if out:
                out[-1].hyphen_after = True
            continue
        if _is_dash(tok.text):
            # A dash one word space after a word is punctuation ("swell —"). One standing well
            # apart, under a note, is a placeholder: this verse sings nothing there (85's "—"
            # under the note only verse 2 sings).
            if out and i and tok.x0 - tokens[i - 1].x1 < 2 * WORD_SPACE:
                out[-1].text += tok.text
            continue
        # Lyrics follow the soprano; prefer its heads unless another part's is clearly closer.
        _, dist, start = min((abs(cx - tok.cx) + (1.5 if rank else 0), abs(cx - tok.cx), t)
                             for cx, t, _, rank in cols)
        if dist > 12:
            warnings.append(f"{where}: syllable '{tok.text}' is {dist:.1f}pt from the nearest note")
        if re.search(r"[\x00-\x1f\ufffd]", tok.text):
            warnings.append(f"{where}: syllable {tok.text!r} has a character the PDF gives no text for")
        if out and start <= out[-1].start:
            warnings.append(f"{where}: syllable '{tok.text}' at beat {start:g} is not after '{out[-1].text}' "
                            f"at {out[-1].start:g}")
        out.append(Syllable(tok.text, start))
    return verse, out


def assign_syllabic(lines: list[list[Syllable]]) -> None:
    for line in lines:
        prev_hyphen = False
        for s in line:
            if s.hyphen_after:
                s.syllabic = "middle" if prev_hyphen else "begin"
            else:
                s.syllabic = "end" if prev_hyphen else "single"
            prev_hyphen = s.hyphen_after


def _fit(tokens: list[Token], cols) -> float:
    """How far the worst-placed word of a lyric row is from the nearest of these noteheads."""
    words = [t for t in tokens if t.text not in HYPHENS and not _is_dash(t.text) and not re.fullmatch(r"\d+\.", t.text)]
    if not words or not cols:
        return float("inf")
    return max(min(abs(cx - t.cx) for cx, *_ in cols) for t in words)


def build_sections(pages, systems, notes, columns, rest_columns, end, warnings) -> list[dict]:
    """Group the systems into sections and time their lyrics.

    Consecutive systems with the same number of full lyric rows form a section. A lower row
    whose words sit under bass-staff notes that the treble staff doesn't have (a men's echo,
    "Peace, be still") is not a full row: it becomes a line with `parts`, which replaces the
    main line for those parts from its first syllable (`start`) to `end`. A section can also
    end mid-system: when only the next section's rows continue after a barline (a chorus
    printed on the middle row of a verse system), the section ends at that barline and the
    rest of that row starts the next section.
    """
    read_lyrics(pages, systems)
    for sys in systems:
        cols = columns[sys.index]
        treble, bass = [c for c in cols if c[3] < 2], [c for c in cols if c[3] >= 2]
        full, men = [], []
        for k, row in enumerate(sys.lyric_lines):
            if k > 0 and not re.fullmatch(r"\d+\.", row[0].text) and _fit(row, bass) <= 3 and _fit(row, treble) > 4.5:
                men.append(row)
            else:
                full.append(row)
        sys.lyric_lines, sys.part_lines = full, men

    groups: list[list[System]] = []
    for sys in systems:
        if groups and len(groups[-1][-1].lyric_lines) == len(sys.lyric_lines):
            groups[-1].append(sys)
        else:
            groups.append([sys])
    for a, b in zip(groups, groups[1:]):
        sys, n_next = a[-1], len(b[0].lyric_lines)
        rows = sys.lyric_lines
        if not 0 < n_next < len(rows):
            continue
        for x in sorted(sys.barlines):
            after = [row for row in rows if any(t.x0 > x for t in row)]
            if len(after) == n_next and all(any(t.x1 < x for t in row) for row in rows):
                sys.carry = [[t for t in row if t.x0 > x] for row in after]
                sys.lyric_lines = [[t for t in row if t.x0 <= x] for row in rows]
                sys.carry_x = x
                break

    sections = []
    for gi, group in enumerate(groups):
        n_lines = len(group[0].lyric_lines)
        lines: list[list[Syllable]] = [[] for _ in range(n_lines)]
        verses: list[int | None] = [None] * n_lines
        prev = groups[gi - 1][-1] if gi else None
        pieces = [(prev, prev.carry)] if prev is not None and prev.carry else []
        pieces += [(sys, sys.lyric_lines) for sys in group]
        for sys, rows in pieces:
            for li, toks in enumerate(rows):
                v, syls = syllables_for_line(toks, columns[sys.index], warnings, f"system {sys.index} line {li + 1}")
                verses[li] = verses[li] or v
                lines[li] += syls
        assign_syllabic(lines)
        if pieces[0][0] is not group[0]:  # starts after a barline inside the previous system
            sys = pieces[0][0]
            start = min(t for cx, t, _, _ in rest_columns[sys.index] if cx > sys.carry_x)
        else:
            start = min(n.start for seq in notes.values() for n in seq if n.head.system is group[0])
        kind = "verse" if n_lines > 1 or gi == 0 else "chorus"
        section = {
            "kind": kind,
            "start": start,
            "lyrics": [{"verse": verses[li] if n_lines > 1 else None,
                        "syllables": [{"start": s.start, "text": s.text, "syllabic": s.syllabic} for s in line]}
                       for li, line in enumerate(lines)],
        }
        # Rows sung by the bass staff's parts only, timed against their notes.
        men: list[Syllable] = []
        for sys in group:
            for toks in sys.part_lines:
                cols = [c for c in columns[sys.index] if c[3] >= 2]
                men += syllables_for_line(toks, cols, warnings, f"system {sys.index} {PARTS[BASS]} line")[1]
        if men:
            assign_syllabic([men])
            onsets = {p: {n.start for n in notes[p] if not n.rest} for p in PARTS[BASS]}
            parts = [p for p in PARTS[BASS] if all(x.start in onsets[p] for x in men)]
            if not parts:
                warnings.append(f"section {gi}: the {PARTS[BASS]} line doesn't follow either part's rhythm")
            main = lines[0] if lines else []
            line_end = next((x.start for x in main if x.start > men[-1].start), None)
            section["lyrics"].append({
                "verse": None, "parts": parts, "start": men[0].start, "end": line_end,
                "syllables": [{"start": s.start, "text": s.text, "syllabic": s.syllabic} for s in men]})
        sections.append(section)
    for a, b in zip(sections, sections[1:]):
        a["end"] = b["start"]
    sections[-1]["end"] = end
    for s in sections:
        for line in s["lyrics"]:
            if line.get("end") is None and "parts" in line:
                line["end"] = s["end"]
    return sections


# --- whole document -----------------------------------------------------------


def _paragraphs(tokens: list[Token], continues) -> list[str]:
    """Group a column of footer text into printed lines, then join each line for which
    continues(line_tokens) is true onto the one before it."""
    rows: list[list[Token]] = []
    for t in sorted(tokens, key=lambda t: (round(t.y), t.x0)):
        if rows and abs(rows[-1][0].y - t.y) < 2:
            rows[-1].append(t)
        else:
            rows.append([t])
    paras: list[str] = []
    for row in rows:
        text = re.sub(r" - ", "-", " ".join(t.text for t in row))
        if paras and continues(row):
            paras[-1] += " " + text
        else:
            paras.append(text)
    return paras


def _footer_top(tokens: list[Token]) -> float:
    """y where the footer credits start: the first credit label, an italic "Text:", "Music:",
    "Text and music:"... at the start of a line."""
    labels = []
    for row in _rows(tokens):
        lead = " ".join(t.text for t in itertools.takewhile(lambda t: t.italic, row))
        if re.fullmatch(r"(Text|Music|Words)( and (text|music|words))?:", lead, re.I):
            labels.append(row[0].y)
    return min(labels) - 2 if labels else float("inf")


def _footer_columns(tokens: list[Token], mid: float) -> tuple[list[Token], list[Token]]:
    """Split the footer into credits (left) and scripture references (right). A line's right
    column starts at the first word past the middle of the page that follows a wide gap, so
    a long credit line that runs past the middle stays whole."""
    left, right = [], []
    for row in _rows(tokens):
        k = next((k for k, t in enumerate(row) if t.x0 >= mid and (k == 0 or t.x0 - row[k - 1].x1 > 15)), len(row))
        left += row[:k]
        right += row[k:]
    return left, right


def _rows(tokens: list[Token]) -> list[list[Token]]:
    rows: list[list[Token]] = []
    for t in sorted(tokens, key=lambda t: (round(t.y), t.x0)):
        if rows and abs(rows[-1][0].y - t.y) < 2:
            rows[-1].append(t)
        else:
            rows.append([t])
    return [sorted(r, key=lambda t: t.x0) for r in rows]


def _text_verses(tokens: list[Token]) -> list[tuple[int, list[list[Token]]]]:
    """Verses printed as a poem, in one or more columns, each starting with its number ("5.").
    A column starts at the x of its verse numbers."""
    starts: list[float] = []
    for x in sorted(t.x0 for t in tokens if re.fullmatch(r"\d+\.", t.text)):
        if not starts or x - starts[-1] > 20:
            starts.append(x)
    edges = [-float("inf")] + [x - 2 for x in starts[1:]] + [float("inf")]
    verses: list[tuple[int, list[list[Token]]]] = []  # (number, printed lines)
    for lo, hi in zip(edges, edges[1:]):
        column = [t for t in tokens if lo <= t.x0 < hi]
        for row in _rows(column):
            if re.fullmatch(r"\d+\.", row[0].text):
                verses.append((int(row[0].text[:-1]), [row[1:]]))
            elif verses:
                verses[-1][1].append(row)
    return sorted(verses, key=lambda v: v[0])


def _fit_text_verse(number: int, rows: list[list[Token]], printed: list[list[dict]], strength,
                    warnings: list[str]) -> dict:
    """Map a poem verse's syllables onto the start times of a printed verse.

    `printed` holds one printed verse (its syllables) for each distinct rhythm, the first
    verse's first. Rhythms differ when a verse has an extra syllable on an optional note.
    The poem verse takes the first rhythm its words can be split to fit exactly. If none fits
    (the poem verse is shorter, e.g. it drops a feminine ending), its syllables are laid out
    by stress against the metre and the printed phrases (`strength(t)` gives a beat's metric
    weight), and the line is marked `approximate`.
    """
    parts: list[list] = []  # [word, hyphenated to the next word]
    line_starts: set[int] = set()
    for row in rows:
        line_starts.add(len(parts))
        for t in row:
            if t.text in HYPHENS:
                if parts:
                    parts[-1][1] = True
            elif _is_dash(t.text):
                if parts:
                    parts[-1][0] += t.text
            else:
                parts.append([t.text, False])
    text = " ".join(w + ("-" if h else "") for w, h in parts).replace("- ", "-")
    words = [w for w, _ in parts]
    line = {"verse": number, "fromText": True, "text": text, "syllables": []}
    placed = None  # [(pieces, start times) per word]
    for verse in printed:
        fitted = fit_words(words, len(verse))
        if fitted is not None:
            starts = iter(s["start"] for s in verse)
            placed = [(pieces, [next(starts) for _ in pieces]) for pieces in fitted]
            break
    if placed is None:
        best = None
        for verse in printed:
            # A printed phrase starts after a syllable that ends in punctuation.
            slots = [(strength(s["start"]), k == 0 or bool(re.search(r"[,.;:!?—]$", verse[k - 1]["text"])))
                     for k, s in enumerate(verse)]
            aligned = align_words(words, line_starts, slots)
            if aligned is not None and (best is None or aligned[0] < best[0]):
                best = (aligned[0], [(pieces, [verse[j]["start"] for j in idxs]) for pieces, idxs in aligned[1]])
        if best is None:
            counts = "/".join(str(len(v)) for v in printed)
            warnings.append(f"verse {number}: couldn't lay the text onto {counts} syllables")
            return line
        placed = best[1]
        line["approximate"] = True
    syls = [Syllable(piece, start, k < len(pieces) - 1 or hyph)
            for (_, hyph), (pieces, starts) in zip(parts, placed) for k, (piece, start) in enumerate(zip(pieces, starts))]
    assign_syllabic([syls])
    line["syllables"] = [{"start": x.start, "text": x.text, "syllabic": x.syllabic} for x in syls]
    return line


def metric_strength(measures: list[dict], meters: list[dict]):
    """strength(t): 3 on a downbeat, 2 mid-measure in duple metres, 1 on other beats, 0 between beats."""
    def strength(t: float) -> float:
        m = [m for m in measures if m["start"] <= t + 1e-6][-1]
        meter = [x for x in meters if x["start"] <= m["start"] + 1e-6][-1]
        length = meter["beats"] * 4 / meter["beatType"]
        compound = meter["beatType"] == 8 and meter["beats"] % 3 == 0
        beat = 1.5 if compound else 4 / meter["beatType"]
        pos = t - (m["start"] + m["duration"] - length)  # a short (pickup) measure is its bar's end
        if abs(pos) < 1e-6:
            return 3
        if meter["beats"] % 2 == 0 and abs(pos - length / 2) < 1e-6:
            return 2
        return 1 if abs(pos / beat - round(pos / beat)) < 1e-6 else 0
    return strength


def extract(pdf_path: str, number: int | None = None) -> dict:
    doc = pymupdf.open(pdf_path)
    maestro_map, text_map = unmapped_maestro_glyphs(doc), unmapped_text_codes(doc)
    pages = [read_page(p, i + 1, maestro_map, text_map) for i, p in enumerate(doc)]
    warnings: list[str] = []
    systems = build_systems(pages)
    if not systems:
        tokens = [t for p in pages for t in p.tokens]
        footer_y = _footer_top(tokens)
        head, foot = [t for t in tokens if t.y < footer_y], [t for t in tokens if t.y >= footer_y]
        left, right = _footer_columns(foot, pages[0].width / 2)
        notice = [" ".join(t.text for t in row) for row in _rows(head)]
        notice += _paragraphs(left, continues=lambda row: not row[0].italic)
        notice += _paragraphs(right, continues=lambda row: False)
        raise NoMusicError(f"no staves in the PDF: {' '.join(notice)}")

    # Maestro glyphs above the music belong to the tempo mark (its augmentation dot is a small
    # Maestro 'k' beside the EngraverTextT note), not to the notation.
    first = systems[0]
    header_glyphs = [g for g in pages[0].glyphs if g.y < first.treble.top - 2 * first.treble.spacing]
    pages[0].glyphs = [g for g in pages[0].glyphs if g not in header_glyphs]

    for sys in systems:
        page = pages[sys.page - 1]
        for st in sys.staves:
            xs = sorted(v.x for v in page.vlines
                        if v.width >= STEM_MAX_WIDTH and abs(v.y0 - st.top) < 1.5 and abs(v.y1 - st.bottom) < 1.5
                        and v.x > st.x0 + 3)
            # A double barline (section end, meter change) or final barline is two lines a
            # little apart: one barline.
            xs = [x for k, x in enumerate(xs) if k == 0 or x - xs[k - 1] > 1.5 * st.spacing]
            if st is sys.treble:
                sys.barlines = xs
            elif [round(x) for x in xs] != [round(x) for x in sys.barlines]:
                warnings.append(f"system {sys.index}: treble and bass barlines differ")

    chords, all_heads = [], []
    for page in pages:
        c, h = build_chords(page, systems, warnings)
        chords += c
        all_heads += h
    unknown = sorted({g.char for p in pages for g in p.glyphs}
                     - set(HEAD_BEATS) - set(REST_BEATS) - set(ACCIDENTALS) - FLAGS - set(FERMATAS) - PARENS
                     - {DOT, TREBLE, BASS}
                     - set("0123456789"))
    if unknown:
        warnings.append(f"unhandled music glyphs: {unknown}")

    first_head_x = min(h.x for h in all_heads if h.system is first)
    fifths = read_key_signature(pages[0], first.treble, first_head_x)
    signatures = [(sys, x, b, bt) for sys in systems for x, b, bt in read_time_signatures(pages[sys.page - 1], sys.treble)]
    if not signatures or signatures[0][0] is not first:
        raise ExtractionError("no time signature on the first system")

    voicings = read_voicings(pages, systems, warnings)
    parts, cues = assign_parts(chords, voicings, warnings)
    apply_tuplets(pages, systems, parts, warnings)
    notes, measures, meters = lay_out_time(parts, systems, fifths, signatures, warnings)
    place_cues(cues, notes, fifths, warnings)
    check_columns(notes, warnings)
    columns = {sys.index: time_columns(sys, notes) for sys in systems}
    rest_columns = {sys.index: time_columns(sys, notes, rests=True) for sys in systems}

    end = measures[-1]["start"] + measures[-1]["duration"]
    sections = build_sections(pages, systems, notes, columns, rest_columns, end, warnings)

    # Below the last system: optional extra verses printed as a poem, then the footer credits.
    last = systems[-1]
    last_page = pages[last.page - 1]
    below = [t for t in last_page.tokens if t.y > last.bass.bottom + 15]
    footer_y = _footer_top(below)
    mid = last_page.width / 2
    verse_section = next((s for s in sections if s["kind"] == "verse"), sections[0])
    rhythms = [[s["start"] for s in line["syllables"]] for line in verse_section["lyrics"]]
    printed = [line["syllables"] for k, line in enumerate(verse_section["lyrics"]) if rhythms[k] and rhythms[k] not in rhythms[:k]]
    strength = metric_strength(measures, meters)
    for verse_no, rows in _text_verses([t for t in below if t.y < footer_y]):
        verse_section["lyrics"].append(_fit_text_verse(verse_no, rows, printed, strength, warnings))

    # Optional notes depend on the verse, so they wait for all the lyrics.
    apply_ties([(p.number, p.curves) for p in pages], systems, notes, warnings)
    for n in (n for seq in notes.values() for n in seq if n.optional):
        section = [s for s in sections if s["start"] <= n.start + 1e-6][-1]
        n.verses = sorted(line["verse"] for line in section["lyrics"] if line["verse"] is not None
                          and any(abs(x["start"] - n.start) < 1e-6 for x in line["syllables"]))
    apply_fermatas(pages, systems, notes, warnings)

    # A section with one lyric line sings it for every verse (verse null). Lines for only
    # some parts (a men's echo) are sung alongside the main line, so they aren't verses.
    rows = [[line for line in s["lyrics"] if "parts" not in line] for s in sections]
    verse_count = max(len(r) for r in rows)
    form = []
    for v in range(1, verse_count + 1):
        for si, r in enumerate(rows):
            form.append({"section": si, "verse": v if len(r) > 1 else None})

    intro = _read_intro(pages, systems, rest_columns, end)
    voicing = []
    for sys_index, x, v in voicings:
        after = [n.start for seq in notes.values() for n in seq if (n.head.system.index, n.head.x) >= (sys_index, x)]
        if after and (not voicing or voicing[-1]["voicing"] != v):
            voicing.append({"start": min(after), "voicing": v})

    page1 = pages[0]
    header = [t for t in page1.tokens if t.y < first.treble.top - 15]
    big = max(t.size for t in header)
    title_tokens = [t for t in header if abs(t.size - big) < 0.5]
    digits = [t for t in title_tokens if re.fullmatch(r"\d+", t.text)]
    hymn_number = number or (int(digits[0].text) if digits else None)
    title = " ".join(t.text for t in sorted(title_tokens, key=lambda t: t.x0) if t not in digits)
    small = [t for t in page1.tokens if first.treble.top - 30 < t.y < first.treble.top]
    tempo_text = " ".join(t.text for t in small if not t.italic)
    m = re.search(r"(\d+)\s*[–-]\s*(\d+)", tempo_text) or re.search(r"(\d+)", tempo_text)
    tempo = {"beatUnit": "quarter", "min": int(m.group(1)), "max": int(m.group(m.lastindex))} if m else None
    unit = next((g for g in page1.tempo_glyphs if g.char in TEMPO_UNITS), None)
    if tempo and unit:
        tempo["beatUnit"] = TEMPO_UNITS[unit.char]
        if any(g.char == "k" and 0 <= g.x0 - unit.x1 < 8 and abs(g.y - unit.y) < 1 for g in header_glyphs):
            tempo["dotted"] = True
    expression = " ".join(t.text for t in small if t.italic) or None

    credit_tokens = [t for t in below if t.y >= footer_y]
    left, right = _footer_columns(credit_tokens, mid)
    credits = _paragraphs(left, continues=lambda row: not row[0].italic)
    # A reference continues onto the next line when that line is only "chapter:verse".
    references = _paragraphs(right,
                             continues=lambda row: bool(re.match(r"\d+:\d", row[0].text)))

    bass_final = [n for n in notes["bass"] if not n.rest][-1]
    tonic = MAJOR_TONIC_BY_FIFTHS[fifths]
    tonic_pc = (STEP_SEMITONES[STEP_NAMES.index(tonic[0])] + (tonic[1:] == "#") - (tonic[1:] == "b")) % 12
    mode = "major" if bass_final.midi % 12 == tonic_pc else "minor" if bass_final.midi % 12 == (tonic_pc + 9) % 12 else None

    return {
        "schemaVersion": 1,
        "number": hymn_number,
        "title": title,
        "source": {"pdf": pdf_path.rsplit("/", 1)[-1], "pages": [{"width": p.width, "height": p.height} for p in pages]},
        "expression": expression,
        "tempo": tempo,
        "key": {"fifths": fifths, "mode": mode},
        "time": {"beats": meters[0]["beats"], "beatType": meters[0]["beatType"]},
        **({"timeChanges": meters} if len(meters) > 1 else {}),
        "credits": credits,
        "references": references,
        "measures": measures,
        "sections": sections,
        "form": form,
        "intro": intro,
        **({"voicing": voicing} if voicing else {}),
        "parts": {part: [_note_json(n) for n in seq] for part, seq in notes.items()},
        "systems": [{"page": s.page, "top": s.treble.top, "bottom": s.bass.bottom,
                     "x0": s.treble.x0, "x1": s.treble.x1} for s in systems],
        "warnings": warnings,
    }


def _note_json(n: Note) -> dict:
    out = {"start": n.start, "duration": n.duration}
    if n.rest:
        out["rest"] = True
    else:
        out["midi"], out["pitch"] = n.midi, n.name
    out["measure"] = n.measure
    if n.fermata:
        out["fermata"] = True
    if n.alts:
        out["alt"] = [{"midi": a.midi, "pitch": a.name, "heads": _heads_json(a)} for a in n.alts]
    if n.optional:
        out["verses"] = n.verses
    out["heads"] = _heads_json(n)
    return out


def _heads_json(n: Note) -> list[dict]:
    return [{"page": h.glyph.page, "system": h.system.index, "x": round(h.cx, 2), "y": round(h.y, 2)} for h in n.heads]


def _read_intro(pages, systems, columns, end) -> list[dict]:
    """⌜ ... ⌝ brackets mark the passage the organist plays as an introduction."""
    marks = []
    for page in pages:
        for g in page.brackets:
            sys = min((s for s in systems if s.page == page.number), key=lambda s: s.treble.distance(g.y))
            cols = columns[sys.index]
            if g.char == "⌜":  # starts at the first note after it
                after = [t for cx, t, _, _ in cols if cx > g.x0]
                marks.append((g.char, min(after) if after else max(e for _, _, e, _ in cols)))
            else:  # ends when the last note (or rest) before it ends
                before = [e for cx, _, e, _ in cols if cx < g.x1]
                marks.append((g.char, max(before) if before else min(t for _, t, _, _ in cols)))
    marks.sort(key=lambda m: m[1])
    intro, start = [], None
    for char, t in marks:
        if char == "⌜":
            start = t
        elif start is not None:
            intro.append({"start": start, "end": t})
            start = None
    return intro
