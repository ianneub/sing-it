"""Hymn 6, Redeemer of Israel: checked by hand against the printed page."""

import json
from pathlib import Path

import pytest

from hymnpdf.extract import extract

ROOT = Path(__file__).resolve().parents[2]
PDF = ROOT / "hymns/pdf/0006-redeemer-of-israel.pdf"
GOLDEN = ROOT / "hymns/json/0006-redeemer-of-israel.json"

# Hymn files aren't in the repository (they're the Church's); see the README to fetch them.
pytestmark = pytest.mark.skipif(not (PDF.exists() and GOLDEN.exists()), reason="needs the hymn's PDF and golden JSON (see README)")


@pytest.fixture(scope="module")
def score():
    return extract(str(PDF))


def test_extracts_without_warnings(score):
    assert score["warnings"] == []


def test_sharp_key(score):
    assert score["key"] == {"fifths": 2, "mode": "major"}  # D major: F# and C#
    first_alto = [n["pitch"] for n in score["parts"]["alto"][:3]]
    assert first_alto == ["D4", "D4", "C#4"]


def test_references_split_on_book_names(score):
    assert score["references"] == ["Exodus 13:21–22", "1 Nephi 22:12"]


def test_poem_verses_are_timed_like_printed_verses(score):
    (verses,) = score["sections"]
    assert [line["verse"] for line in verses["lyrics"]] == [1, 2, 3, 4, 5, 6]
    printed = [s["start"] for s in verses["lyrics"][0]["syllables"]]
    for line in verses["lyrics"][4:]:
        assert line["fromText"] is True
        assert [s["start"] for s in line["syllables"]] == printed
    v6 = verses["lyrics"][5]["syllables"]
    assert [s["text"] for s in v6[-8:]] == ["Re", "e", "choes", "the", "praise", "of", "the", "Lord."]
    assert [s["syllabic"] for s in v6[-8:-5]] == ["begin", "middle", "end"]


def test_form_covers_all_six_verses(score):
    assert [f["verse"] for f in score["form"]] == [1, 2, 3, 4, 5, 6]


def test_intro_bracket_after_last_note_of_a_line(score):
    # ⌝ at the far right of line 1 includes the pickup "On" (beat 16-17)
    assert score["intro"] == [{"start": 0.0, "end": 17.0}, {"start": 45.0, "end": 56.0}]


def test_golden_file_is_current(score):
    assert json.loads(GOLDEN.read_text()) == score
