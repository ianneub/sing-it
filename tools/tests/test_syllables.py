"""Syllable splitting for verses printed as a poem. Needs no hymn files: the texts are
public domain (Psalm 100, William Kethe, 1561; the Doxology, Thomas Ken, 1674)."""

from hymnpdf.syllables import fit_words, syllable_options

PSALM = "All people that on earth do dwell, Sing to the Lord with cheerful voice".split()
DOXOLOGY = "Praise God, from whom all blessings flow; Praise him above, ye heav'nly host;".split()


def test_counts_from_the_pronouncing_dictionary():
    assert syllable_options("people") == [2]
    assert syllable_options("cheerful") == [2]
    assert syllable_options("Lord") == [1]


def test_fits_a_long_metre_line_to_eight_notes():
    fitted = fit_words(PSALM[:7], 8)  # "All people that on earth do dwell,"
    assert fitted is not None
    assert [piece for word in fitted for piece in word] == ["All", "peo", "ple", "that", "on", "earth", "do", "dwell,"]


def test_fits_two_lines_and_keeps_punctuation_and_contractions():
    fitted = fit_words(DOXOLOGY, 16)
    assert fitted is not None
    flat = [piece for word in fitted for piece in word]
    assert len(flat) == 16
    assert flat[5:8] == ["bless", "ings", "flow;"]
    assert "host;" in flat


def test_refuses_when_the_words_cannot_fill_the_notes():
    assert fit_words(PSALM[:7], 12) is None
