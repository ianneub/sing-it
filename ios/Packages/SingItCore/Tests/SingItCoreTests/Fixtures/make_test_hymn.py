"""Generate test-hymn.json and test-hymn.beatmap.json: a small made-up four-part hymn in the
app's hymn format, so the core tests run without any of the Church's hymn files.

The tune and harmony are written for these tests; the words are public domain (Psalm 100,
William Kethe, 1561; the Doxology, Thomas Ken, 1674).

    python3 make_test_hymn.py
"""

import json
from pathlib import Path

HERE = Path(__file__).parent
NAMES = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]

# Melody, one quarter note per syllable, four lines of eight (G major).
MELODY = [
    [67, 67, 66, 64, 62, 67, 69, 71],
    [71, 71, 71, 69, 67, 72, 71, 69],
    [67, 69, 71, 69, 67, 64, 66, 67],
    [74, 71, 67, 69, 72, 71, 69, 67],
]
CHORDS = {"G": [7, 11, 2], "C": [0, 4, 7], "D": [2, 6, 9], "Em": [4, 7, 11]}
CHOICE = {7: "G", 11: "G", 2: "G", 0: "C", 4: "C", 6: "D", 9: "D"}  # melody pitch class -> chord
ROOT = {"G": 7, "C": 0, "D": 2, "Em": 4}

VERSES = {
    1: ["All peo-ple that on earth do dwell,", "Sing to the Lord with cheer-ful voice;",
        "Him serve with fear, his praise forth tell;", "Come ye be-fore him and re-joice."],
    2: ["Praise God, from whom all bless-ings flow;", "Praise him, all crea-tures here be-low;",
        "Praise him a-bove, ye heav'n-ly host;", "Praise Fa-ther, Son, and Ho-ly Ghost."],
}


def name(midi):
    return NAMES[midi % 12] + str(midi // 12 - 1)


def voice_below(chord, below, low):
    """Highest chord tone at least two semitones under `below` and not under `low`."""
    tones = [m for m in range(low, below - 1) if m % 12 in CHORDS[chord]]
    return tones[-1]


def near(chord, low, high, centre):
    tones = [m for m in range(low, high + 1) if m % 12 in CHORDS[chord]]
    return min(tones, key=lambda m: abs(m - centre))


def note(start, midi, measure, system, line, i):
    return {"start": float(start), "duration": 1.0, "midi": midi, "pitch": name(midi), "measure": measure,
            "heads": [{"page": 1, "system": system, "x": 60.0 + 40 * i, "y": 100.0 + 120 * (line % 2)}]}


def syllables(line_text, start):
    out = []
    for word in line_text.split():
        pieces = word.split("-")
        for k, piece in enumerate(pieces):
            syllabic = "single" if len(pieces) == 1 else "begin" if k == 0 else "end" if k == len(pieces) - 1 else "middle"
            out.append({"start": float(start + len(out)), "text": piece, "syllabic": syllabic})
    assert len(out) == 8, line_text
    return out


def main():
    parts = {p: [] for p in ("soprano", "alto", "tenor", "bass")}
    for line, tune in enumerate(MELODY):
        for i, soprano in enumerate(tune):
            start = line * 8 + i
            chord = CHOICE[soprano % 12]
            alto = voice_below(chord, soprano, 59)
            tenor = near(chord, 55, 67, 60)
            bass = max(m for m in range(43, 56) if m % 12 == ROOT[chord])  # the chord's root
            for part, midi in zip(parts, (soprano, alto, tenor, bass)):
                parts[part].append(note(start, midi, start // 4 + 1, line // 2, line, i))
    lyrics = []
    for verse, lines in VERSES.items():
        syls = []
        for line, text in enumerate(lines):
            syls += syllables(text, line * 8)
        lyrics.append({"verse": verse, "syllables": syls})
    hymn = {
        "schemaVersion": 1, "number": 9999, "title": "Test Hymn", "expression": "Steadily",
        "tempo": {"beatUnit": "quarter", "min": 84, "max": 96},
        "key": {"fifths": 1, "mode": "major"}, "time": {"beats": 4, "beatType": 4},
        "credits": ["Text: Psalm 100, William Kethe, 1561; Thomas Ken, 1674 (public domain)",
                    "Music: written for Sing It's tests"],
        "references": [],
        "measures": [{"start": float(4 * m), "duration": 4.0, "number": m + 1} for m in range(8)],
        "sections": [{"kind": "verse", "start": 0.0, "end": 32.0, "lyrics": lyrics}],
        "form": [{"section": 0, "verse": 1}, {"section": 0, "verse": 2}],
        "intro": [{"start": 24.0, "end": 32.0}],
        "parts": parts,
        "systems": [{"page": 1, "top": 80.0, "bottom": 180.0, "x0": 40.0, "x1": 400.0},
                    {"page": 1, "top": 200.0, "bottom": 300.0, "x0": 40.0, "x1": 400.0}],
        "warnings": [],
    }
    (HERE / "test-hymn.json").write_text(json.dumps(hymn, indent=1) + "\n")

    # A recording at 90 bpm: an eight-beat introduction, then both verses.
    rate, intro = 1.5, 8
    start = intro / rate
    beats = [[round(start + b / rate, 3), b] for b in [k / 8 for k in range(64 * 8)]]
    beatmap = {"url": "https://example.com/test-hymn.mp3", "number": 9999, "audio": "test-hymn.mp3",
               "duration": round(start + 64 / rate + 2, 3), "introStart": 0.0, "singingStart": start,
               "beats": beats, "alignmentCost": 0.0}
    (HERE / "test-hymn.beatmap.json").write_text(json.dumps(beatmap) + "\n")


if __name__ == "__main__":
    main()
