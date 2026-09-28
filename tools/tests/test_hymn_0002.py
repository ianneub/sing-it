"""Hymn 2, The Spirit of God: checked by hand against the printed page."""

import json
from pathlib import Path

import pytest

from hymnpdf.extract import extract

ROOT = Path(__file__).resolve().parents[2]
PDF = ROOT / "hymns/pdf/0002-the-spirit-of-god.pdf"
GOLDEN = ROOT / "hymns/json/0002-the-spirit-of-god.json"

# Hymn files aren't in the repository (they're the Church's); see the README to fetch them.
pytestmark = pytest.mark.skipif(not (PDF.exists() and GOLDEN.exists()), reason="needs the hymn's PDF and golden JSON (see README)")


@pytest.fixture(scope="module")
def score():
    return extract(str(PDF))


def notes_at(score, part, start):
    return [n for n in score["parts"][part] if n["start"] == start]


def test_extracts_without_warnings(score):
    assert score["warnings"] == []


def test_header(score):
    assert score["number"] == 2
    assert score["title"] == "The Spirit of God"
    assert score["key"] == {"fifths": -2, "mode": "major"}
    assert score["time"] == {"beats": 4, "beatType": 4}
    assert score["tempo"] == {"beatUnit": "quarter", "min": 96, "max": 112}
    assert score["expression"] == "Exultantly"
    assert score["references"] == ["Doctrine and Covenants 109:79–80", "Doctrine and Covenants 110"]


def test_measures(score):
    ms = score["measures"]
    assert len(ms) == 33
    assert ms[0] == {"start": 0.0, "duration": 1.0, "number": 0}  # pickup
    assert ms[-1]["duration"] == 3.0  # completes the pickup
    assert all(m["duration"] == 4.0 for m in ms[1:-1])


def test_every_part_is_continuous(score):
    for part, notes in score["parts"].items():
        assert notes[0]["start"] == 0
        for a, b in zip(notes, notes[1:]):
            assert a["start"] + a["duration"] == b["start"], (part, a["start"])
        assert notes[-1]["start"] + notes[-1]["duration"] == 128.0


def test_soprano_opening_phrase(score):
    got = [(n["pitch"], n["duration"]) for n in score["parts"]["soprano"][:14]]
    assert got == [
        ("F4", 1), ("Bb4", 2), ("C5", 1), ("C5", 1), ("D5", 2), ("C5", 1), ("Bb4", 1),
        ("Bb4", 2), ("A4", 1), ("G4", 1), ("F4", 1.5), ("G4", 0.5), ("F4", 1), ("Eb4", 1),
    ]


def test_parts_sharing_a_stem_split_top_and_bottom(score):
    assert notes_at(score, "soprano", 0)[0]["pitch"] == "F4"
    assert notes_at(score, "alto", 0)[0]["pitch"] == "D4"
    assert notes_at(score, "tenor", 0)[0]["pitch"] == "Bb3"
    assert notes_at(score, "bass", 0)[0]["pitch"] == "Bb2"


def test_unison_drawn_as_duplicate_heads(score):
    # m2 "God": tenor and bass both on Bb3
    assert notes_at(score, "tenor", 5)[0]["pitch"] == "Bb3"
    assert notes_at(score, "bass", 5)[0]["pitch"] == "Bb3"


def test_tie_merges_notes(score):
    # m3 "fire ___ is": tenor Bb3 half tied to a quarter
    (n,) = notes_at(score, "tenor", 9)
    assert (n["pitch"], n["duration"], len(n["heads"])) == ("Bb3", 3, 2)


def test_side_by_side_heads_of_different_parts(score):
    # m25 "glo-ry": tenor Bb3 half, bass Bb3 quarter drawn beside it, then down to D3
    assert [(n["pitch"], n["duration"]) for n in score["parts"]["tenor"] if 97 <= n["start"] < 101] == [
        ("Bb3", 2), ("A3", 1), ("Bb3", 1)]
    assert [(n["pitch"], n["duration"]) for n in score["parts"]["bass"] if 97 <= n["start"] < 101] == [
        ("Bb3", 1), ("D3", 1), ("F3", 1), ("Bb3", 1)]


def test_courtesy_natural(score):
    # m19 "mies of": alto E natural against the Bb-major key signature
    assert notes_at(score, "alto", 76)[0]["pitch"] == "E4"


def test_sections_and_lyrics(score):
    verse, chorus = score["sections"]
    assert (verse["kind"], verse["start"], verse["end"]) == ("verse", 0, 64)
    assert (chorus["kind"], chorus["start"], chorus["end"]) == ("chorus", 64, 128)
    assert [line["verse"] for line in verse["lyrics"]] == [1, 2, 3, 4]
    v1 = verse["lyrics"][0]["syllables"]
    assert [(s["text"], s["start"], s["syllabic"]) for s in v1[:5]] == [
        ("The", 0, "single"), ("Spir", 1, "begin"), ("it", 3, "end"), ("of", 4, "single"), ("God", 5, "single")]
    assert v1[7]["text"] == "fire"  # the ﬁ ligature is normalised
    (line,) = chorus["lyrics"]
    assert line["verse"] is None
    assert " ".join(s["text"] for s in line["syllables"][-5:]) == "A men and a men!"


def test_form_and_intro(score):
    assert score["form"][:3] == [{"section": 0, "verse": 1}, {"section": 1, "verse": None},
                                 {"section": 0, "verse": 2}]
    assert len(score["form"]) == 8
    assert score["intro"] == [{"start": 0.0, "end": 15.0}, {"start": 111.0, "end": 128.0}]


def test_golden_file_is_current(score):
    """If extraction changes on purpose, regenerate with the command in CLAUDE.md."""
    assert json.loads(GOLDEN.read_text()) == score
