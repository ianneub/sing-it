"""Engraving rules that the Ghostscript/TeX hymn PDFs exercise, checked by hand against the pages."""

import glob
import json
from fractions import Fraction
from functools import cache
from pathlib import Path

import pytest

from hymnpdf.__main__ import main
from hymnpdf.extract import NoMusicError, extract

ROOT = Path(__file__).resolve().parents[2]
PDFS = sorted(glob.glob(str(ROOT / "hymns/pdf/*.pdf")))
NO_MUSIC = {"0086", "0124"}  # licensing notice instead of music

# Hymn files aren't in the repository (they're the Church's); see the README to fetch the
# development set of 20 PDFs and generate their golden JSON.
pytestmark = pytest.mark.skipif(len(PDFS) < 20, reason="needs the 20-hymn development set in hymns/pdf (see README)")

# Checked by hand against the printed pages: time signatures ("beats/type@start"), key
# (fifths, mode), numbered verses printed under the music, verses printed as a poem below
# it, whether there is a chorus, the total length in beats, and the soprano's opening notes
# (tied notes merged, as in the JSON; "r" is a rest).
FACTS = {
    "0019": (["4/4@0"], 2, "major", 3, 0, False, 64,
             "D4/0.75 E4/0.25 F#4/1 F#4/0.75 E4/0.25 D4/0.75 E4/0.25 F#4/0.75 G4/0.25"),
    "0026": (["4/4@0"], -2, "major", 4, 0, False, 64,
             "D4/0.75 Eb4/0.25 F4/1 F4/1 F4/1 Bb4/1 Bb4/1 A4/2 A4/0.75 Bb4/0.25"),
    "0027": (["2/4@0"], 0, "major", 4, 0, True, 64, "C4/1 C4/0.75 C4/0.25 E4/0.5 C4/0.5 E4/0.5 G4/0.5 C5/1"),
    "0030": (["4/4@0", "3/4@8", "4/4@14", "3/4@22"], 1, "major", 4, 0, False, 52,
             "G4/1 G4/0.75 A4/0.25 B4/1.5 G4/0.5 F#4/0.5 G4/0.5 A4/0.5"),
    # The pickup's dotted eighth and sixteenth are tied for verse 1, so they merge.
    "0060": (["4/4@0"], -2, "major", 3, 0, True, 64, "F4/1 F4/0.75 F4/0.25 F4/0.75 Eb4/0.25 D4/0.75 F4/0.25"),
    "0085": (["4/4@0"], -4, "major", 3, 4, False, 80, "Eb4/1 Ab4/2 Ab4/1 C5/1 Eb4/2 Eb4/1 F4/1 Eb4/1 Db4/1 C4/1 Eb4/1 Ab4/3"),
    "0098": (["3/4@0"], 1, "major", 4, 0, True, 48, "G4/1 B4/1.5 A4/0.5 G4/0.5 F#4/0.5 G4/2 G4/1 G4/1.5"),
    "0105": (["6/8@0"], 0, "major", 3, 0, True, 108, "G4/0.5 A4/0.5 G4/0.5 G4/0.5 C5/0.5 E5/0.5 D5/1.5 A4/1 C5/0.5"),
    "0116": (["3/4@0"], 0, "major", 4, 2, False, 48, "E4/1 C4/1 F4/1 E4/2 G4/1 C5/1 B4/1 A4/1"),
    "0136": (["4/4@0"], 1, "major", 4, 0, False, 64,
             "D4/1 D4/1 D4/1 F#4/1 E4/0.5 F#4/0.5 E4/1 D4/1 G4/1 D4/1 D4/1 D4/1 F#4/1 E4/0.5 F#4/0.5"),
    "0152": (["4/4@0"], 0, "major", 3, 0, True, 64, "E4/1.5 E4/0.5 E4/0.5 E4/0.5 E4/0.5 E4/0.5 G4/1 D4/1 E4/2"),
    "0193": (["3/4@0"], -4, "major", 3, 0, True, 72, "Eb4/1 Eb4/1 Ab4/1 F4/1 Eb4/1 C4/1 Db4/1 Eb4/1"),
    "0204": (["6/4@0"], -2, "major", 3, 0, False, 72, "F4/1.5 G4/0.5 F4/1 D4/3 F4/1.5 G4/0.5 F4/1 D4/3"),
    "0227": (["4/4@0"], 1, "major", 4, 0, True, 64, "G4/0.75 A4/0.25 B4/1 D4/1 E4/0.75 F#4/0.25 G4/0.75 A4/0.25"),
    "0239": (["4/4@0"], 0, "major", 3, 0, True, 64, "E4/1 F4/1 G4/1.5 G4/0.25 G4/0.25 A4/0.5 C5/0.5 B4/0.5"),
    # 301 is still under copyright, so its notes aren't quoted here; its golden JSON covers them.
    "0301": (["4/4@0"], 2, "major", 3, 0, True, 64, ""),
}


@cache
def score(number: str) -> dict:
    (path,) = glob.glob(str(ROOT / f"hymns/pdf/{number}-*.pdf"))
    return extract(path)


def notes(number, part, lo=0, hi=1e9):
    return [n for n in score(number)["parts"][part] if lo <= n["start"] < hi]


def rhythm(number, part, lo, hi):
    return [(n.get("pitch", "rest"), n["duration"]) for n in notes(number, part, lo, hi)]


def line_text(line):
    return " ".join(s["text"] + ("-" if s["syllabic"] in ("begin", "middle") else "") for s in line["syllables"])


@pytest.mark.parametrize("path", PDFS, ids=lambda p: Path(p).name[:4])
def test_extracts_cleanly_with_the_printed_number(path):
    prefix = Path(path).name[:4]
    if prefix in NO_MUSIC:
        with pytest.raises(NoMusicError, match="licensing"):
            extract(path)
        return
    s = score(prefix)
    assert s["warnings"] == []
    assert s["number"] == int(prefix)
    assert json.loads((ROOT / "hymns/json" / (Path(path).stem + ".json")).read_text()) == s
    end = s["measures"][-1]["start"] + s["measures"][-1]["duration"]
    for part, seq in s["parts"].items():  # every part is contiguous from the first beat to the last
        assert seq[0]["start"] == 0
        for a, b in zip(seq, seq[1:]):
            assert a["start"] + a["duration"] == pytest.approx(b["start"]), (part, a["start"])
        assert seq[-1]["start"] + seq[-1]["duration"] == pytest.approx(end), part
        for n in seq:  # each note's measure is the one it starts in
            m = [m for m in s["measures"] if m["start"] <= n["start"]][-1]
            assert n["measure"] == m["number"], (part, n["start"])
    # Times are exact, even after a triplet: parts, measures and lyrics meet on equal values.
    times = [n["start"] for seq in s["parts"].values() for n in seq] + [m["start"] for m in s["measures"]]
    times += [x["start"] for sec in s["sections"] for line in sec["lyrics"] for x in line["syllables"]]
    assert all(t == float(Fraction(t).limit_denominator(96)) for t in times)
    # Every sung pass names a lyric line of its section: verse null means the section's one line.
    for f in s["form"]:
        rows = [line for line in s["sections"][f["section"]]["lyrics"] if "parts" not in line]
        assert len(rows) == 1 if f["verse"] is None else any(line["verse"] == f["verse"] for line in rows)


@pytest.mark.parametrize("number", sorted(FACTS))
def test_hand_checked_facts(number):
    meters, fifths, mode, printed, poem, chorus, beats, opening = FACTS[number]
    s = score(number)
    changes = s.get("timeChanges", [{"start": 0.0, **s["time"]}])
    assert [f"{c['beats']}/{c['beatType']}@{c['start']:g}" for c in changes] == meters
    assert s["key"] == {"fifths": fifths, "mode": mode}
    lines = [line for sec in s["sections"] for line in sec["lyrics"] if "parts" not in line]
    assert len({line["verse"] for line in lines if line["verse"] and not line.get("fromText")}) == printed
    assert sum(bool(line.get("fromText")) for line in lines) == poem
    assert any(sec["kind"] == "chorus" for sec in s["sections"]) == chorus
    assert s["measures"][-1]["start"] + s["measures"][-1]["duration"] == beats
    sop = [f"{n.get('pitch', 'r')}/{n['duration']:g}" for n in s["parts"]["soprano"]]
    assert " ".join(sop[:len(opening.split())]) == opening


def test_no_music_is_a_clean_cli_status(capsys):
    for number in NO_MUSIC:
        (path,) = glob.glob(str(ROOT / f"hymns/pdf/{number}-*.pdf"))
        assert main([path, "--dump"]) == 0
        err = capsys.readouterr().err
        assert "Due to licensing limitations" in err and "Traceback" not in err
    # Credits run past the middle of the page; the references column starts after a wide gap.
    with pytest.raises(NoMusicError, match=r"original words are works and mighty\. Music:.*Psalm 8:3–9; 9:1–2 Mosiah"):
        extract(glob.glob(str(ROOT / "hymns/pdf/0086-*.pdf"))[0])


def test_half_notes_without_unicode_mapping():
    # 0027 prints its half notehead from a Maestro subset with no ToUnicode; m8 "Seer." is a half note.
    assert [rhythm("0027", p, 14, 16) for p in ("soprano", "alto", "tenor", "bass")] == [
        [("D4", 2.0)], [("B3", 2.0)], [("G3", 2.0)], [("G2", 2.0)]]
    assert score("0027")["key"]["mode"] == "major"


def test_beams_drawn_as_rectangles_and_sixteenth_stubs():
    # 0105 m1: six beamed eighths (flat beams are filled rectangles).
    assert [d for _, d in rhythm("0105", "soprano", 0, 3)] == [0.5] * 6
    # 0027 m1: dotted eighth + sixteenth (the sixteenth has a partial beam).
    assert rhythm("0027", "soprano", 0, 2) == [("C4", 1.0), ("C4", 0.75), ("C4", 0.25)]


def test_rests_take_time():
    # 0301 m8: a dotted half then a quarter rest in every part.
    for part in ("soprano", "alto", "tenor", "bass"):
        assert [d for _, d in rhythm("0301", part, 28, 32)][-1:] == [1.0]
        assert rhythm("0301", part, 31, 32)[0][0] == "rest"
    # 0204 m10: quarter rest after the tied notes ("peace;").
    assert all(m["duration"] == 6 for m in score("0204")["measures"][1:-1])
    assert score("0204")["intro"] == [{"start": 0.0, "end": 12.0}, {"start": 60.0, "end": 72.0}]


def test_meter_changes():
    s = score("0030")
    assert s["time"] == {"beats": 4, "beatType": 4}
    assert [(c["start"], c["beats"], c["beatType"]) for c in s["timeChanges"]] == [
        (0.0, 4, 4), (8.0, 3, 4), (14.0, 4, 4), (22.0, 3, 4)]
    assert "timeChanges" not in score("0002")


def test_fermatas():
    held = [(p, n["pitch"], n["start"]) for p in ("soprano", "bass") for n in score("0030")["parts"][p] if n.get("fermata")]
    assert held == [("soprano", "G4", 26.0), ("bass", "G3", 26.0)]  # m8 "day."


def test_cue_note_is_an_alternative_pitch():
    # Final chord of 0030 and 0136: small G2 under the bass G3.
    for number in ("0030", "0136"):
        last = score(number)["parts"]["bass"][-1]
        assert (last["pitch"], [a["pitch"] for a in last["alt"]]) == ("G3", ["G2"])
        assert score(number)["parts"]["tenor"][-1]["pitch"] == "B3"


def test_optional_notes_over_a_rest_are_sung_by_one_verse():
    # 0085 m12: parenthesized cue chord over a quarter rest, for verse 2's "As".
    got = [(p, n["pitch"], n["verses"]) for p in ("soprano", "alto", "tenor", "bass")
           for n in notes("0085", p, 47, 48)]
    assert got == [("soprano", "Eb4", [2]), ("alto", "C4", [2]), ("tenor", "Ab3", [2]), ("bass", "Ab2", [2])]


def test_detached_dash_is_a_placeholder_not_punctuation():
    # 0085 m12: verses 1 and 3 print "—" under the note only verse 2 sings; 0030's "swell —" is punctuation.
    lines = score("0085")["sections"][0]["lyrics"]
    assert [[x["text"] for x in lines[v]["syllables"] if 45 <= x["start"] < 48] for v in range(3)] == [
        ["said,"], ["sea—", "As"], ["stand,"]]
    assert "swell—" in line_text(score("0030")["sections"][0]["lyrics"][0])


def test_echo_lines_are_not_verses():
    for number in ("0105", "0152"):
        assert [f["verse"] for f in score(number)["form"]] == [1, None, 2, None, 3, None]


def test_poem_verses_that_drop_syllables_are_laid_out_by_stress():
    lines = {line["verse"]: line for line in score("0085")["sections"][0]["lyrics"]}
    assert len(lines[4]["syllables"]) == 56 and "approximate" not in lines[4]
    v5 = lines[5]
    assert v5["approximate"] is True
    starts = {s["start"]: s["text"] for s in v5["syllables"]}
    # "Thy dross to con-sume, thy dross to con-sume," holds "sume" over the missing "-ior".
    assert [starts.get(t) for t in (48, 49, 51, 52, 53, 55, 56)] == ["Thy", "dross", "to", "con", "sume,", None, "thy"]
    # "fiery" may be sung in two syllables (like "fire"), which puts "TRI-als" on the downbeat.
    assert [starts[t] for t in (3, 4, 5, 7)] == ["fie", "ry", "tri", "als"]


def test_dotted_tempo_unit():
    assert score("0105")["tempo"] == {"beatUnit": "quarter", "min": 52, "max": 66, "dotted": True}


def test_mens_echo_line():
    chorus = score("0105")["sections"][1]
    assert (chorus["kind"], chorus["start"]) == ("chorus", 47.5)
    main, echo = chorus["lyrics"]
    assert (echo["parts"], echo["start"], echo["end"]) == (["tenor", "bass"], 54.0, 60.0)
    assert [(s["text"], s["start"]) for s in echo["syllables"]] == [
        ("Peace,", 54.0), ("be", 55.0), ("still,", 55.5), ("peace,", 57.0), ("be", 58.0), ("still.", 58.5)]
    s152 = score("0152")
    assert [sec["kind"] for sec in s152["sections"]] == ["verse", "chorus"]
    assert s152["sections"][1]["lyrics"][1]["parts"] == ["tenor", "bass"]


def test_chorus_starting_mid_system():
    verse, chorus = score("0060")["sections"]
    assert (verse["end"], chorus["start"]) == (33.0, 33.0)
    assert line_text(chorus["lyrics"][0]).startswith("Glo- ry, glo- ry, hal- le- lu- jah!")


def test_triplet():
    # 0227 m9 beat 4: three eighths in the time of two.
    assert [d for _, d in rhythm("0227", "soprano", 36, 37)] == pytest.approx([1 / 3] * 3)


def test_unison_passage_and_voicing_labels():
    s = score("0136")
    assert s["voicing"] == [{"start": 0.0, "voicing": "unison"}, {"start": 32.0, "voicing": "harmony"}]
    for sop, alto, bass in zip(notes("0136", "soprano", 0, 32), notes("0136", "alto", 0, 32), notes("0136", "bass", 0, 32)):
        assert alto["midi"] == sop["midi"] and bass["midi"] == sop["midi"] - 12
    assert score("0193")["voicing"][0] == {"start": 0.0, "voicing": "duet"}


def test_text_from_unmapped_ligatures():
    words = line_text(score("0027")["sections"][0]["lyrics"][3])
    assert "Sac- ri- fice" in words and "con- flict" in words


def test_poem_syllables_start_with_legal_onsets():
    text = {line["verse"]: line_text(line) for line in score("0116")["sections"][0]["lyrics"]}
    assert "king- doms," in text[6] and "do- min- ions," in text[6]
    assert "What- e’er" in text[5]


def test_multi_word_credit_label():
    assert score("0193")["credits"] == ["Text and music: Charles H. Gabriel, 1856–1932"]
