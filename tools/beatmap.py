"""Align a hymn recording (the Church's accompaniment MP3) to the hymn's notes.

Produces a beat map: for moments of the audio, the beat of the *performance* being played
(the same beat numbering the app uses: every pass through the form, back to back), plus
where the organ introduction plays. The app uses it in practice mode to know exactly
where the singer should be; tools use it as ground truth for testing the follower.

    .venv/bin/python tools/beatmap.py hymns/json/0002-the-spirit-of-god.json \\
        hymns/audio/0002-the-spirit-of-god.accompaniment.mp3 -o hymns/beatmaps/0002-the-spirit-of-god.json

Method: chroma (energy per note name) from the audio, the same from the notes of all four
parts, then dynamic time warping. The recording plays the introduction (the ⌜ ⌝ bracketed
passages) and then every pass of the form; its tempo is free to vary.
"""

from __future__ import annotations

import argparse
import json
import subprocess

import numpy as np

SR = 22050
HOP = 0.1  # seconds per audio frame
STEP = 0.125  # beats per score frame (about one audio frame at hymn tempos)


def decode(path: str, sr: int = SR) -> np.ndarray:
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-ac", "1", "-ar", str(sr), "-f", "f32le", "-"],
                         check=True, capture_output=True).stdout
    return np.frombuffer(raw, dtype=np.float32)


def audio_chroma(x: np.ndarray, sr: int = SR, hop: float = HOP) -> tuple[np.ndarray, np.ndarray]:
    """(chroma frames x 12, RMS per frame)."""
    n_fft = 8192
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


def score_chroma(hymn: dict) -> tuple[np.ndarray, np.ndarray]:
    """Chroma per score frame, and each frame's performance beat (-1 during the intro)."""
    notes = [n for part in ("soprano", "alto", "tenor", "bass") for n in hymn["parts"][part] if n.get("midi") is not None]
    rows, beats = [], []
    for kind, _, a, b, perf in performance_segments(hymn):
        for w in np.arange(a, b, STEP):
            v = np.zeros(12)
            for n in notes:
                if n["start"] <= w < n["start"] + n["duration"]:
                    v[n["midi"] % 12] += 1.5 if n in hymn["parts"]["bass"] else 1  # bass is strong on an organ
            rows.append(v)
            beats.append(-1 if kind == "intro" else perf + (w - a))
    return normalise(np.array(rows) + 0.05), np.array(beats)


def dtw(cost: np.ndarray) -> list[tuple[int, int]]:
    """Slope-constrained DTW path through cost[audio, score] from (0, 0) to the end.

    Steps are (1,1), (2,1) and (1,2), so the local tempo stays within half to double the
    nominal rate: a recording with a steady tempo can't be matched by racing through one
    verse and dawdling in the next, which free DTW does on hymns (every verse has the same
    music).
    """
    n, m = cost.shape
    inf = np.inf
    acc = np.full((n, m), inf)
    move = np.zeros((n, m), dtype=np.int8)  # 0: (1,1)  1: (2,1)  2: (1,2)
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
        acc[i], move[i] = np.where(take, d, best), np.where(take, 2, mv)
    i, j = n - 1, m - 1
    if not np.isfinite(acc[i, j]):
        raise ValueError("recording and score lengths are too different for the tempo limits")
    path = [(i, j)]
    while i > 0 or j > 0:
        mv = move[i, j]
        if mv == 0:
            i, j = i - 1, j - 1
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


def smooth(times: np.ndarray, window: int) -> np.ndarray:
    """Local straight-line fit over +-window score frames, then made non-decreasing. Inside a
    held chord every moment looks alike, so raw DTW times wander; the tempo is steady."""
    out = np.empty_like(times)
    idx = np.arange(len(times))
    for k in range(len(times)):
        lo, hi = max(0, k - window), min(len(times), k + window + 1)
        slope, intercept = np.polyfit(idx[lo:hi], times[lo:hi], 1)
        out[k] = slope * k + intercept
    return np.maximum.accumulate(out)


def align(hymn: dict, audio_path: str) -> dict:
    x = decode(audio_path)
    chroma, rms = audio_chroma(x)
    # Trim leading and trailing silence.
    loud = np.where(rms > 0.05 * rms.max())[0]
    first, last = int(loud[0]), int(loud[-1]) + 1
    sc, beats = score_chroma(hymn)
    cost = 1 - chroma[first:last] @ sc.T
    path = dtw(cost)

    # For each score frame, the audio time of its first audio frame: when that beat starts.
    start_of = {}
    for i, j in path:
        start_of.setdefault(j, (first + i) * HOP)
    js = np.array(sorted(start_of))
    times = smooth(np.array([start_of[j] for j in js]), window=int(6 / STEP))
    points = [(round(float(t), 3), round(float(beats[j]), 3)) for t, j in zip(times, js)]
    intro = [t for t, b in points if b < 0]
    passes = [(t, b) for t, b in points if b >= 0]
    mean_cost = float(np.mean([cost[i, j] for i, j in path]))
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
