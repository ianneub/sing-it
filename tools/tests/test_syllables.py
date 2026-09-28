"""Syllable splitting for verses printed as a poem. Needs no hymn files: the text is Alma
29:1-2 from the Book of Mormon (public domain, first published 1830)."""

from hymnpdf.syllables import fit_words, syllable_options

VERSE_1 = "O that I were an angel, and could have the wish of mine heart,".split()
VERSE_2 = "Yea, I would declare unto every soul, as with the voice of thunder,".split()


def test_counts_from_the_pronouncing_dictionary():
    assert syllable_options("angel") == [2]
    assert syllable_options("thunder") == [2]
    assert syllable_options("heart") == [1]


def test_fits_a_phrase_to_its_notes():
    fitted = fit_words(VERSE_1[:6], 7)  # "O that I were an angel,"
    assert fitted is not None
    assert [piece for word in fitted for piece in word] == ["O", "that", "I", "were", "an", "an", "gel,"]


def test_keeps_punctuation_and_chooses_pronunciations_to_fit():
    # "every" can be two syllables or three; the notes decide.
    for notes, every in ((17, 2), (18, 3)):
        fitted = fit_words(VERSE_2, notes)
        assert fitted is not None, notes
        assert len(fitted[VERSE_2.index("every")]) == every
        assert fitted[-1][-1] == "der,"


def test_refuses_when_the_words_cannot_fill_the_notes():
    assert fit_words(VERSE_1[:6], 12) is None
