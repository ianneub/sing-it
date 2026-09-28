"""Align a hymn recording (the Church's accompaniment MP3) to the hymn's notes.

Produces a beat map: for moments of the audio, the beat of the *performance* being played
(the same beat numbering the app uses: every pass through the form, back to back), plus
where the organ introduction plays. The app uses it in practice mode to know exactly
where the singer should be; tools use it as ground truth for testing the follower.

    .venv/bin/python tools/beatmap.py hymns/json/0002-the-spirit-of-god.json \\
        hymns/audio/0002-the-spirit-of-god.accompaniment.mp3 -o hymns/beatmaps/0002-the-spirit-of-god.json

Method: chroma (energy per note name) from the audio, the same from the notes of all four
parts, then dynamic time warping. The recording plays the introduction (the ⌜ ⌝ bracketed
passages) and then every pass of the form; its tempo is free to vary. Between passages the
organist breathes: the last chord is held or the music stops for a moment, and the next
passage starts only after that. The score has a "breath" frame at every such boundary that
matches quiet audio, and the alignment may wait on it or on a passage's last chord.
Without it, the next verse was placed up to 2 s before the music got there (the
introduction's last chord and the verse's first are often the same).
"""

from __future__ import annotations

import argparse
import json
import subprocess

import numpy as np

SR = 22050
HOP = 0.1  # seconds per audio frame
N_FFT = 8192  # samples per analysis window (0.37 s); a frame's time is its window's centre
ONSET_WEIGHT = 1.0  # cost of a score note start where the audio has no attack
HOLD_COST = 0.15  # per frame of holding a passage's last chord longer than written
SILENCE_WEIGHT = 0.5  # cost of a sounding note on near-silent audio
SMOOTH_BEATS = 0.5  # half-width of the local fit (the onsets place the beats; this irons out the jitter)
STEP = 0.125  # beats per score frame (about one audio frame at hymn tempos)


def decode(path: str, sr: int = SR) -> np.ndarray:
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-ac", "1", "-ar", str(sr), "-f", "f32le", "-"],
                         check=True, capture_output=True).stdout
    return np.frombuffer(raw, dtype=np.float32)


def audio_chroma(x: np.ndarray, sr: int = SR, hop: float = HOP) -> tuple[np.ndarray, np.ndarray]:
    """(chroma frames x 12, RMS per frame)."""
    n_fft = N_FFT
    h = int(sr * hop)
    window = np.hanning(n_fft)
    frames = max(1, 1 + (len(x) - n_fft) // h)
    freqs = np.fft.rfftfreq(n_fft, 1 / sr)
    band = (freqs >= 60) & (freqs <= 2000)
    pcs = (np.round(12 * np.log2(freqs[band] / 440.0)) + 9) % 12  # pitch class of each bin (C = 0)
    onehot = np.zeros((band.sum(), 12))
    onehot[np.arange(band.sum()), pcs.astype(int)] = 1
    chroma = np.zeros((frames, 12))
    rms = np.zeros(frames)
    for i in range(frames):
        seg = x[i * h:i * h + n_fft]
        if len(seg) < n_fft:
            seg = np.pad(seg, (0, n_fft - len(seg)))
        rms[i] = np.sqrt(np.mean(seg ** 2))
        spec = np.abs(np.fft.rfft(seg * window))[band]
        chroma[i] = np.log1p(100 * spec) @ onehot
    return normalise(chroma), rms


def audio_detail(x: np.ndarray, frames: int, sr: int = SR, hop: float = HOP) -> tuple[np.ndarray, np.ndarray]:
    """Per audio frame, from short windows (a chroma window is too long to place an attack
    or see a quarter-second breath), over that frame's hop around its time (its chroma
    window's centre): how strongly a note starts (0..1, spectral flux), and how quiet the
    quietest moment is (0 silent .. 1 as loud as a tenth of the loudest)."""
    n, h = 1024, 256
    count = max(1, 1 + (len(x) - n) // h)
    spec = np.log1p(100 * np.abs(np.fft.rfft(np.lib.stride_tricks.sliding_window_view(x, n)[::h][:count]
                                             * np.hanning(n), axis=1)))
    flux = np.concatenate([[0], np.maximum(0, np.diff(spec, axis=0)).sum(1)])
    level = np.sqrt(np.mean(np.lib.stride_tricks.sliding_window_view(x, n)[::h][:count] ** 2, axis=1))
    flux_t = (np.arange(count) * h + n / 2) / sr
    # Normalise against the local level so quiet verses count as much as loud ones.
    local = np.convolve(flux, np.ones(int(2 * sr / h)) / int(2 * sr / h), "same")
    strength = np.clip(flux / (2 * local + 1e-9) - 0.5, 0, 1)
    attack, quiet = np.zeros(frames), np.ones(frames)
    centre = np.arange(frames) * hop + N_FFT / 2 / sr
    idx = np.searchsorted(flux_t, centre - hop / 2)
    span = int(hop * sr / h) + 1
    for i in range(frames):
        j = idx[i]
        if j < count:
            attack[i] = strength[j:j + span].max()
            quiet[i] = min(1, level[j:j + span].min() / (0.1 * level.max()))
    return attack, quiet


def normalise(c: np.ndarray) -> np.ndarray:
    c = c - c.min(axis=1, keepdims=True)
    n = np.linalg.norm(c, axis=1, keepdims=True)
    return c / np.where(n > 0, n, 1)


def performance_segments(hymn: dict) -> list[tuple[str, int, float, float, float]]:
    """(kind, pass index, written start, written end, performance start) in playing order:
    the introduction passages, then each pass of the form."""
    segs = []
    for r in hymn["intro"]:
        segs.append(("intro", -1, r["start"], r["end"], None))
    t = 0.0
    for i, entry in enumerate(hymn["form"]):
        s = hymn["sections"][entry["section"]]
        segs.append(("pass", i, s["start"], s["end"], t))
        t += s["end"] - s["start"]
    return segs


PUNCTUATION = ",.;:!?—–"


def phrase_ends(hymn: dict) -> list[float]:
    """Written beats where the organist may breathe inside a passage: after a note with a
    fermata, before a rest in the melody, and before the syllable after punctuation in any
    verse (the breath comes just before the next word)."""
    ends = set()
    for part in hymn["parts"].values():
        ends |= {n["start"] + n["duration"] for n in part if n.get("fermata")}
    melody = hymn["parts"]["soprano"]
    ends |= {a["start"] + a["duration"] for a, b in zip(melody, melody[1:])
             if a.get("midi") is not None and b.get("midi") is None}
    for section in hymn["sections"]:
        for line in section["lyrics"]:
            syllables = line["syllables"]
            for a, b in zip(syllables, syllables[1:]):
                if a["text"].rstrip("\"'’”)").endswith(tuple(PUNCTUATION)):
                    ends.add(b["start"])
    return sorted(ends)


def score_chroma(hymn: dict) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    """Chroma per score frame, each frame's performance beat (-1 during the intro, NaN for a
    breath), its stretch of steady tempo (a breath belongs to none: -1), whether a note
    starts in it, and whether every part rests. A breath frame sits between passages and at
    phrase ends inside them; its chroma row is zero (the cost of matching it, like a rest's,
    comes from loudness)."""
    notes = [n for part in ("soprano", "alto", "tenor", "bass") for n in hymn["parts"][part] if n.get("midi") is not None]
    ends = phrase_ends(hymn)
    rows, beats, segment, onsets, silent = [], [], [], [], []
    stretch = 0

    def breathe() -> None:
        nonlocal stretch
        rows.append(np.zeros(12))
        beats.append(np.nan)
        segment.append(-1)
        onsets.append(False)
        silent.append(True)
        stretch += 1

    for k, (kind, _, a, b, perf) in enumerate(performance_segments(hymn)):
        if k > 0:
            breathe()
        for w in np.arange(a, b, STEP):
            # Not near a passage's ends, where the breath between passages serves (a comma
            # after a verse's first word let the verse start before the pause).
            if a + 2 < w < b - 2 and any(w - STEP / 2 < e <= w + STEP / 2 for e in ends):
                breathe()
            onsets.append(any(w - 1e-6 <= n["start"] < w + STEP - 1e-6 for n in notes))
            v = np.zeros(12)
            for n in notes:
                if n["start"] <= w < n["start"] + n["duration"]:
                    v[n["midi"] % 12] += 1.5 if n in hymn["parts"]["bass"] else 1  # bass is strong on an organ
            rows.append(v)
            beats.append(-1 if kind == "intro" else perf + (w - a))
            segment.append(stretch)
            silent.append(not v.any())
    chroma = normalise(np.array(rows) + 0.05)
    chroma[np.array(segment) < 0] = 0
    return chroma, np.array(beats), np.array(segment), np.array(onsets), np.array(silent)


def dtw(cost: np.ndarray, wait: np.ndarray | None = None, wait_cost: np.ndarray | None = None) -> list[tuple[int, int]]:
    """Slope-constrained DTW path through cost[audio, score] from (0, 0) to the end.

    Steps are (1,1), (2,1) and (1,2), so the local tempo stays within half to double the
    nominal rate: a recording with a steady tempo can't be matched by racing through one
    verse and dawdling in the next, which free DTW does on hymns (every verse has the same
    music). At score frames where `wait` is true the path may also stay put, (1,0), for as
    long as the audio needs: a held last chord or a breath, paying `wait_cost` per frame
    on top of the match.
    """
    n, m = cost.shape
    inf = np.inf
    acc = np.full((n, m), inf)
    move = np.zeros((n, m), dtype=np.int8)  # 0: (1,1)  1: (2,1)  2: (1,2)  3: (1,0)
    wait = np.zeros(m, dtype=bool) if wait is None else wait
    wait_cost = np.zeros(m) if wait_cost is None else wait_cost
    acc[0, 0] = cost[0, 0]
    for i in range(1, n):
        c = cost[i]
        a = np.full(m, inf)
        a[1:] = acc[i - 1, :-1] + 2 * c[1:]
        best, mv = a, np.zeros(m, dtype=np.int8)
        if i >= 2:
            b = np.full(m, inf)
            b[1:] = acc[i - 2, :-1] + 2 * cost[i - 1, 1:] + c[1:]
            take = b < best
            best, mv = np.where(take, b, best), np.where(take, 1, mv)
        d = np.full(m, inf)
        d[2:] = acc[i - 1, :-2] + 2 * c[1:-1] + c[2:]
        take = d < best
        best, mv = np.where(take, d, best), np.where(take, 2, mv)
        h = np.where(wait, acc[i - 1] + c + wait_cost, inf)
        take = h < best
        acc[i], move[i] = np.where(take, h, best), np.where(take, 3, mv)
    i, j = n - 1, m - 1
    if not np.isfinite(acc[i, j]):
        raise ValueError("recording and score lengths are too different for the tempo limits")
    path = [(i, j)]
    while i > 0 or j > 0:
        mv = move[i, j]
        if mv == 0:
            i, j = i - 1, j - 1
            path.append((i, j))
        elif mv == 3:
            i -= 1
            path.append((i, j))
        elif mv == 1:
            path.append((i - 1, j))
            i, j = i - 2, j - 1
            path.append((i, j))
        else:
            path.append((i, j - 1))
            i, j = i - 1, j - 2
            path.append((i, j))
    return path[::-1]


def smooth(times: np.ndarray, window: int, segment: np.ndarray) -> np.ndarray:
    """Local straight-line fit over +-window score frames of the same passage, then made
    non-decreasing. Inside a held chord every moment looks alike, so raw DTW times wander;
    the tempo is steady within a passage, but not across the breath between passages."""
    out = np.empty_like(times)
    idx = np.arange(len(times))
    for k in range(len(times)):
        same = np.where(segment == segment[k])[0]
        lo, hi = max(same[0], k - window), min(same[-1] + 1, k + window + 1)
        if hi - lo < 2:
            out[k] = times[k]
            continue
        slope, intercept = np.polyfit(idx[lo:hi], times[lo:hi], 1)
        out[k] = slope * k + intercept
    return np.maximum.accumulate(out)


def align(hymn: dict, audio_path: str) -> dict:
    x = decode(audio_path)
    chroma, rms = audio_chroma(x)
    # Trim leading and trailing silence.
    loud = np.where(rms > 0.05 * rms.max())[0]
    first, last = int(loud[0]), int(loud[-1]) + 1
    sc, beats, segment, note_starts, silent = score_chroma(hymn)
    cost = 1 - chroma[first:last] @ sc.T
    # Rhythm: a note starting in the score should meet an attack in the audio. Chroma alone
    # can't place beats inside one chord (a verse opening on repeated notes of the tonic
    # was matched at double speed, a second ahead of the music).
    attack, quiet = (d[first:last] for d in audio_detail(x, len(chroma)))
    cost[:, note_starts] += ONSET_WEIGHT * (1 - attack)[:, None]
    # A breath or a rest matches quiet audio: free in silence, as dear as a wrong chord at
    # full volume. A note doesn't match near-silence: a chord dying away at the end of a
    # verse has the next verse's opening notes in it when the verse starts on the tonic too.
    breath = segment < 0
    cost[:, silent] = (quiet ** 2)[:, None]
    cost[:, ~silent] += SILENCE_WEIGHT * (1 - quiet)[:, None]
    # Wait on a breath, or on a passage's last chord (held before the breath). Holding a
    # chord costs a little per frame, or the path can sit on an introduction's last chord
    # for many seconds (it sounds like the verse's first) and then race to catch up.
    held = np.zeros_like(breath)
    held[:-1] = breath[1:]
    held[-1] = True
    wait = breath | held
    path = dtw(cost, wait, np.where(held, HOLD_COST, 0.0))

    # For each score frame, the audio time of its first audio frame (the centre of its
    # window): when that beat starts. Breath frames have no beat.
    start_of = {}
    for i, j in path:
        if not breath[j]:
            start_of.setdefault(j, (first + i) * HOP + N_FFT / 2 / SR)
    js = np.array(sorted(start_of))
    times = smooth(np.array([start_of[j] for j in js]), int(SMOOTH_BEATS / STEP), segment[js])
    points = [(round(float(t), 3), round(float(beats[j]), 3)) for t, j in zip(times, js)]
    # Where the organist lets go and breathes (at least two quiet frames), the note ends
    # then: the position reaches the end of the note as the music stops and waits there.
    # Without this point the silence is spread over the note, which looks held too long.
    held_frames: dict[int, list[int]] = {}
    for i, j in path:
        if breath[j]:
            held_frames.setdefault(j, []).append(i)
    for j, frames in held_frames.items():
        after = beats[j + 1] if j + 1 < len(beats) else np.nan
        if len(frames) >= 2 and after >= 0:
            points.append((round((first + frames[0]) * HOP + N_FFT / 2 / SR, 3), round(float(after) - 0.01, 3)))
    points.sort()
    points = [(t, b) for k, (t, b) in enumerate(points) if k == 0 or (t > points[k - 1][0] and b >= points[k - 1][1])]
    intro = [t for t, b in points if b < 0]
    passes = [(t, b) for t, b in points if b >= 0]
    mean_cost = float(np.mean([cost[i, j] for i, j in path if not breath[j]]))
    return {
        "number": hymn["number"],
        "audio": audio_path.rsplit("/", 1)[-1],
        "duration": round(len(x) / SR, 3),
        "introStart": intro[0] if intro else None,
        "singingStart": passes[0][0],
        # [seconds, performance beat] at every quarter beat of the performance
        "beats": [[t, b] for t, b in passes],
        "alignmentCost": round(mean_cost, 4),
    }


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("hymn_json")
    ap.add_argument("audio")
    ap.add_argument("-o", "--output")
    ap.add_argument("--url", help="where the app downloads this recording from (stored in the output)")
    args = ap.parse_args()
    hymn = json.load(open(args.hymn_json))
    result = align(hymn, args.audio)
    if args.url:
        result = {"url": args.url, **result}
    if args.output:
        with open(args.output, "w") as f:
            json.dump(result, f)
            f.write("\n")
    beats = result["beats"]
    per_bar = int(4 / STEP)  # points per 4 beats
    tempo = [60 * (b2 - b1) / (t2 - t1) for (t1, b1), (t2, b2) in zip(beats[::per_bar], beats[per_bar::per_bar]) if t2 > t1]
    print(f"{result['audio']}: {result['duration']}s, intro from {result['introStart']}s, "
          f"singing from {result['singingStart']}s, ends {beats[-1][0]}s at beat {beats[-1][1]}; "
          f"tempo median {np.median(tempo):.0f} bpm (range {np.percentile(tempo, 5):.0f}-{np.percentile(tempo, 95):.0f}); "
          f"mean alignment cost {result['alignmentCost']}")


if __name__ == "__main__":
    main()
