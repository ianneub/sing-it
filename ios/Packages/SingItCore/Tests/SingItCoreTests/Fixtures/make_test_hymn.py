"""Generate test-hymn.json and test-hymn.beatmap.json: a small made-up four-part hymn in the
app's hymn format, so the core tests run without any of the Church's hymn files.

The words are Alma 29:1-2 from the Book of Mormon (public domain, first published 1830),
one verse each. The melody is original, written for these tests, and the other three parts
are generated from it. Each of the five phrases has enough notes for the longer verse; in
the shorter one, the phrase's last syllable is held over the extra notes.

    python3 make_test_hymn.py
"""

import json
from math import ceil
from pathlib import Path

HERE = Path(__file__).parent
NAMES = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]

# Melody (G major), one list per phrase.
MELODY = [
    [67, 69, 71, 71, 72, 74, 74, 72, 71, 69],
    [71, 71, 69, 67, 69, 71, 69, 67],
    [74, 74, 74, 72, 71, 72, 74, 76, 74, 72, 71, 69],
    [71, 72, 74, 71, 67, 69, 71, 72, 71, 69, 67],
    [67, 69, 71, 72, 74, 76, 74, 72, 71, 72, 74, 71, 69, 67, 66, 67],
]
SYSTEMS = [0, 0, 1, 2, 2]  # printed system (display line) of each phrase
CHORDS = {"G": [7, 11, 2], "C": [0, 4, 7], "D": [2, 6, 9]}
CHOICE = {7: "G", 11: "G", 2: "G", 0: "C", 4: "C", 6: "D", 9: "D"}  # melody pitch class -> chord
ROOT = {"G": 7, "C": 0, "D": 2}

# Alma 29:1-2, split into the five phrases at the text's punctuation. Hyphens mark syllables.
VERSES = {
    1: ["O that I were an an-gel,", "and could have the wish of mine heart,",
        "that I might go forth and speak with the trump of God,", "with a voice to shake the earth,",
        "and cry re-pent-ance un-to ev-ery peo-ple!"],
    2: ["Yea, I would de-clare un-to ev-ery soul,", "as with the voice of thun-der,",
        "re-pent-ance and the plan of re-demp-tion,", "that they should re-pent and come un-to our God,",
        "that there might not be more sor-row up-on all the face of the earth."],
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


def phrase_lengths():
    """Beats per phrase: a quarter note per syllable, the last note held to the end of a bar."""
    return [ceil((len(tune) + 1) / 4) * 4 for tune in MELODY]


def note(start, duration, midi, measure, system, i):
    return {"start": float(start), "duration": float(duration), "midi": midi, "pitch": name(midi), "measure": measure,
            "heads": [{"page": 1, "system": system, "x": 60.0 + 24 * i, "y": 100.0 + 120 * system}]}


def syllables(text, notes):
    """The phrase's syllables on its notes' start beats; a short phrase holds its last syllable."""
    pieces = []
    for word in text.split():
        parts = word.split("-")
        for k, part in enumerate(parts):
            syllabic = "single" if len(parts) == 1 else "begin" if k == 0 else "end" if k == len(parts) - 1 else "middle"
            pieces.append((part, syllabic))
    assert len(pieces) <= len(notes), text
    return [{"start": float(start), "text": part, "syllabic": syllabic} for (part, syllabic), start in zip(pieces, notes)]


def main():
    lengths = phrase_lengths()
    total = sum(lengths)
    parts = {p: [] for p in ("soprano", "alto", "tenor", "bass")}
    phrase_starts = []  # the start beat of every note, per phrase
    beat = 0
    for phrase, (tune, length) in enumerate(zip(MELODY, lengths)):
        starts = []
        for i, soprano in enumerate(tune):
            duration = 1 if i < len(tune) - 1 else length - (len(tune) - 1)
            chord = CHOICE[soprano % 12]
            alto = voice_below(chord, soprano, 59)
            tenor = near(chord, 55, 67, 60)
            bass = max(m for m in range(43, 56) if m % 12 == ROOT[chord])  # the chord's root
            for part, midi in zip(parts, (soprano, alto, tenor, bass)):
                parts[part].append(note(beat, duration, midi, int(beat // 4) + 1, SYSTEMS[phrase], i))
            starts.append(beat)
            beat += duration
        phrase_starts.append(starts)
    lyrics = []
    for verse, phrases in VERSES.items():
        syls = []
        for text, starts in zip(phrases, phrase_starts):
            syls += syllables(text, starts)
        lyrics.append({"verse": verse, "syllables": syls})
    intro_start = total - lengths[-1]  # the organ plays the last phrase as an introduction
    hymn = {
        "schemaVersion": 1, "number": 9999, "title": "Test Hymn", "expression": "Earnestly",
        "tempo": {"beatUnit": "quarter", "min": 84, "max": 96},
        "key": {"fifths": 1, "mode": "major"}, "time": {"beats": 4, "beatType": 4},
        "credits": ["Text: Alma 29:1-2, Book of Mormon (1830, public domain)",
                    "Music: written for Sing It's tests"],
        "references": ["Alma 29:1-2"],
        "measures": [{"start": float(4 * m), "duration": 4.0, "number": m + 1} for m in range(total // 4)],
        "sections": [{"kind": "verse", "start": 0.0, "end": float(total), "lyrics": lyrics}],
        "form": [{"section": 0, "verse": 1}, {"section": 0, "verse": 2}],
        "intro": [{"start": float(intro_start), "end": float(total)}],
        "parts": parts,
        "systems": [{"page": 1, "top": 80.0 + 120 * k, "bottom": 180.0 + 120 * k, "x0": 40.0, "x1": 400.0}
                    for k in range(max(SYSTEMS) + 1)],
        "warnings": [],
    }
    (HERE / "test-hymn.json").write_text(json.dumps(hymn, indent=1) + "\n")

    # A recording at 90 bpm: the introduction, then both verses.
    rate, sung = 1.5, 2 * total
    start = lengths[-1] / rate
    beats = [[round(start + b / rate, 3), b] for b in [k / 8 for k in range(sung * 8)]]
    beatmap = {"url": "https://example.com/test-hymn.mp3", "number": 9999, "audio": "test-hymn.mp3",
               "duration": round(start + sung / rate + 2, 3), "introStart": 0.0, "singingStart": start,
               "beats": beats, "alignmentCost": 0.0}
    (HERE / "test-hymn.beatmap.json").write_text(json.dumps(beatmap) + "\n")


if __name__ == "__main__":
    main()
