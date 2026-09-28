"""Split English words into sung syllables.

Only needed for verses printed as a poem below the music, which carry no hyphens.
Syllable counts come from the CMU Pronouncing Dictionary. Some words have several
pronunciations ("blessed" is 1 or 2 syllables), so a whole verse is fitted at once:
choose each word's count so the verse fills the melody's syllables, preferring the
dictionary's first pronunciation. The hyphenation library (pyphen) is only a guide to
*where* to split, because it follows typesetting rules rather than pronunciation: it
leaves "holy" whole and splits "looks" as "look-s".
"""

from __future__ import annotations

import re
from functools import cache

import cmudict
import pyphen

DIGRAPHS = ("th", "ch", "sh", "ph", "wh", "gh", "ck")
HIATUS = ("io", "ia", "eo", "ua", "iu", "ie")  # vowel pairs often sung as two syllables (Zi-on)


@cache
def _cmu() -> dict:
    return cmudict.dict()


@cache
def _hyphenator() -> pyphen.Pyphen:
    return pyphen.Pyphen(lang="en_US")


def _bare(word: str) -> str:
    return re.sub(r"[^a-z]", "", word.lower())


def _vowel_group_count(bare: str) -> int:
    groups = [m.span() for m in re.finditer(r"[aeiouy]+", bare)]
    lone_final_e = bool(groups) and groups[-1] == (len(bare) - 1, len(bare)) and bare[-1] == "e"
    lone_e_before_s_or_d = bool(groups) and groups[-1] == (len(bare) - 2, len(bare) - 1) and bare[-2:] in ("es", "ed")
    silent = (
        (lone_final_e and not bare.endswith("le"))
        or (lone_e_before_s_or_d and bare.endswith("ed") and bare[-3:-2] not in ("t", "d"))
        or (lone_e_before_s_or_d and bare.endswith("es") and not re.search(r"(s|x|z|ch|sh|ce|ge)es$", bare))
    )
    return max(1, len(groups) - (1 if silent and len(groups) > 1 else 0))


def syllable_options(word: str) -> list[int]:
    """Possible syllable counts for a word, most likely first."""
    bare = _bare(word)
    if not bare:
        return [0]
    prons = _pronunciations(bare)
    if prons:
        counts = [sum(ph[-1].isdigit() for ph in p) for p in prons]
        return list(dict.fromkeys(counts))
    return [_vowel_group_count(bare)]


def _pronunciations(bare: str) -> list[list[str]]:
    """The dictionary's pronunciations of a word (or of its singular), then the same with
    each unstressed ER straight after a vowel sung as a glide (fi-ery, pow'r), as the
    dictionary itself lists for "fire" but not for words built on it."""
    for candidate in (bare, bare[:-1] if bare.endswith("s") else None):
        prons = _cmu().get(candidate) if candidate else None
        if prons:
            out = [list(p) for p in prons]
            for p in prons:
                glided = [("R" if ph == "ER0" and k and p[k - 1][-1].isdigit() else ph) for k, ph in enumerate(p)]
                if glided not in out:
                    out.append(glided)
            return out
    return []


def split_word(word: str, n: int) -> list[str]:
    """Split a word into exactly n printable pieces (none for bare punctuation).

    Only the word's letters are hyphenated; leading and trailing punctuation is put back on
    the first and last pieces. Where the hyphenator gives too few pieces, its pieces (which
    respect prefixes and suffixes, un-change-able) are split further between vowel groups.
    """
    if n <= 0:
        return []
    if n == 1:
        return [word]
    m = re.fullmatch(r"([^A-Za-z]*)(.*?)([^A-Za-z]*)", word)
    lead, core, trail = m.groups()
    pieces = _split_core(core, n) if core else [word]
    pieces[0], pieces[-1] = lead + pieces[0], pieces[-1] + trail
    return pieces


def _split_core(word: str, n: int) -> list[str]:
    pieces = _hyphenator().inserted(word).split("-")
    if len(pieces) == n:
        return pieces
    if len(pieces) < n:
        # Give the extra syllables to the pieces that have more than one vowel group.
        need = n - len(pieces)
        counts = [1] * len(pieces)
        for k, piece in sorted(enumerate(pieces), key=lambda kp: -_vowel_group_count(_bare(kp[1]))):
            extra = min(need, _vowel_group_count(_bare(piece)) - 1)
            counts[k] += extra
            need -= extra
        if need == 0:
            split = [_split_by_vowels(p, c) if c > 1 else [p] for p, c in zip(pieces, counts)]
            if all(split):
                return [q for sp in split for q in sp]
    return _split_by_vowels(word, n) or _force(pieces, n)


# Consonant clusters a sung syllable may start with when a word is split between vowels:
# single consonants, digraphs, and a stop or f followed by l or r (ta-ble, re-frain).
TWO_CONSONANT_ONSETS = {a + b for a in "bcdfgkpt" for b in "lr"} - {"dl", "tl"} | set(DIGRAPHS) | {"qu", "thr", "chr", "phr", "shr"}


def _onset_length(cluster: str) -> int:
    """Consonants of a cluster that start the next syllable: the longest legal onset."""
    for k in (3, 2):
        if len(cluster) >= k and cluster[-k:] in TWO_CONSONANT_ONSETS:
            return k
    return 1 if cluster and cluster[-1] not in "x" else 0


def _split_by_vowels(word: str, n: int) -> list[str] | None:
    """Split between vowel groups, starting each syllable with the longest legal onset
    (a-ble, king-doms, broth-er). A vowel after an apostrophe is an elision (e’er), so the
    consonant before it stays with the previous syllable (What-e’er)."""
    lower = word.lower()
    groups = [list(m.span()) for m in re.finditer(r"[aeiouy]+(?:[’'][aeiouy]+)*|[’'][aeiouy]+", lower)]
    # Split two-vowel groups that are often sung as two syllables, e.g. Zi-on.
    i = 0
    while len(groups) < n and i < len(groups):
        a, b = groups[i]
        pair = next((k for k in range(a, b - 1) if lower[k:k + 2] in HIATUS), None)
        if pair is not None:
            groups[i:i + 1] = [[a, pair + 1], [pair + 1, b]]
        i += 1
    groups = groups[:n] if len(groups) >= n else None
    if groups is None:
        return None
    cuts = []
    for (_, a_end), (b_start, b_end) in zip(groups, groups[1:]):
        cluster = lower[a_end:b_start]
        if re.search("[’']", lower[b_start:b_end]):
            cuts.append(b_start)
        else:
            cuts.append(b_start - _onset_length(cluster))
    pieces = [word[a:b] for a, b in zip([0] + cuts, cuts + [len(word)])]
    return pieces if all(any(ch.isalpha() for ch in p) for p in pieces) else None


def _force(pieces: list[str], n: int) -> list[str]:
    pieces = list(pieces)
    while len(pieces) > n:
        pieces[-2:] = [pieces[-2] + pieces[-1]]
    while len(pieces) < n:
        k = max(range(len(pieces)), key=lambda j: len(pieces[j]))
        w = pieces[k]
        pieces[k:k + 1] = [w[: len(w) // 2], w[len(w) // 2:]]
    return pieces


def fit_words(words: list[str], target: int) -> list[list[str]] | None:
    """Split every word so the total is exactly `target` syllables, or None if impossible.

    Among the ways to hit the target, pick the one using the fewest non-preferred
    pronunciations.
    """
    options = [syllable_options(w) for w in words]
    # best[k][t] = (cost, choice) to cover the first k words with t syllables
    best: list[dict[int, tuple[int, list[int]]]] = [{0: (0, [])}]
    for opts in options:
        nxt: dict[int, tuple[int, list[int]]] = {}
        for t, (cost, chosen) in best[-1].items():
            for rank, n in enumerate(opts):
                cand = (cost + (rank > 0), chosen + [n])
                if t + n <= target and (t + n not in nxt or cand[0] < nxt[t + n][0]):
                    nxt[t + n] = cand
        best.append(nxt)
    if target not in best[-1]:
        return None
    return [split_word(w, n) for w, n in zip(words, best[-1][target][1])]


# Unstressed when sung, although the dictionary marks most one-syllable words as stressed.
FUNCTION_WORDS = frozenset(
    "a an the and or but nor of to in on at by for with from as if than so is am are was were be been "
    "shall will can may might must would should could do did has hath have had my thy thine his her its our "
    "your their thee me him us them he she it we they you ye i who whom which that this these those not like "
    "o oh een oer upon unto".split())


def stress_options(word: str) -> list[list[float]]:
    """Possible stress patterns of a word, one value per syllable (1 stressed, 0.5 secondary
    stress, 0 unstressed), most likely first."""
    bare = _bare(word)
    if not bare:
        return [[]]
    prons = _pronunciations(bare)
    if prons:
        patterns: list[list[float]] = []
        for p in prons:
            pattern = [{"1": 1.0, "2": 0.5, "0": 0.0}[ph[-1]] for ph in p if ph[-1].isdigit()]
            if len(pattern) == 1:
                pattern = [0.0 if bare in FUNCTION_WORDS else 1.0]
            if pattern not in patterns:
                patterns.append(pattern)
        return patterns
    n = _vowel_group_count(bare)
    return [[0.0 if n == 1 and bare in FUNCTION_WORDS else 1.0] + [0.0] * (n - 1)]


def align_words(words: list[str], line_starts: set[int], slots: list[tuple[float, bool]],
                max_hold: int = 2) -> tuple[float, list[tuple[list[str], list[int]]]] | None:
    """Lay a poem verse onto a melody whose syllable count it doesn't match exactly.

    `slots` are the printed verse's syllable positions as (metric strength 0-3, starts a
    phrase). Every syllable takes one slot, in order, beginning with the first slot and ending
    on the last. A syllable may hold over up to `max_hold` following slots (as a singer
    stretches a word over a feminine ending the verse doesn't have). The layout minimises
    stressed syllables on weak beats, unstressed ones on strong beats, held slots, poem lines
    that don't start where a printed phrase starts, and less likely pronunciations.
    Returns (cost, [(pieces, slot indexes) per word]), or None if the words can't fit.
    """
    hold_cost, pron_cost, line_cost = 1.0, 1.0, 4.0
    n = len(slots)

    def stress_cost(stress: float, strength: float) -> float:
        return stress * (3 - strength) / 2 + (1 - stress) * max(0.0, strength - 1)

    layer: dict[int, tuple[float, object]] = {-1: (0.0, None)}  # last used slot -> (cost, back pointer)
    history = []
    for w, word in enumerate(words):
        nxt: dict[int, tuple[float, object]] = {}
        for last, (cost, _) in layer.items():
            for rank, pattern in enumerate(stress_options(word)):
                stack = [(0, last, cost + pron_cost * rank, [])]
                while stack:
                    k, prev, acc, idxs = stack.pop()
                    if k == len(pattern):
                        if prev not in nxt or acc < nxt[prev][0]:
                            nxt[prev] = (acc, (last, len(pattern), idxs))
                        continue
                    lo = prev + 1
                    hi = lo if prev < 0 else lo + max_hold
                    for j in range(lo, min(hi, n - 1) + 1):
                        # Holding inside a word is less natural than holding its last syllable.
                        c = acc + hold_cost * (j - lo) * (1.5 if k else 1.0) + stress_cost(pattern[k], slots[j][0])
                        if k == 0 and w in line_starts and not slots[j][1]:
                            c += line_cost
                        stack.append((k + 1, j, c, idxs + [j]))
        history.append(nxt)
        layer = nxt
    if n - 1 not in layer:
        return None
    cost, out, last = layer[n - 1][0], [], n - 1
    for w in range(len(words) - 1, -1, -1):
        prev, count, idxs = history[w][last][1]
        out.append((split_word(words[w], count), idxs))
        last = prev
    return cost, out[::-1]
