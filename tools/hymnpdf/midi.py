"""Write a score as a Standard MIDI File, one track per part, for listening checks."""

from __future__ import annotations

import struct

PPQ = 480
PROGRAMS = {"soprano": 0, "alto": 0, "tenor": 0, "bass": 0}  # acoustic grand piano


def _varlen(n: int) -> bytes:
    out = [n & 0x7F]
    n >>= 7
    while n:
        out.append(0x80 | (n & 0x7F))
        n >>= 7
    return bytes(reversed(out))


def _track(events: list[tuple[int, bytes]]) -> bytes:
    data, now = b"", 0
    for tick, msg in sorted(events, key=lambda e: (e[0], e[1][0] & 0xF0 != 0x80)):
        data += _varlen(tick - now) + msg
        now = tick
    data += b"\x00\xff\x2f\x00"
    return b"MTrk" + struct.pack(">I", len(data)) + data


def performance(score: dict, full_form: bool) -> list[tuple[float, float, float]]:
    """(source start, source end, performed offset) spans: the written score once, or every verse in order."""
    if not full_form:
        end = score["measures"][-1]["start"] + score["measures"][-1]["duration"]
        return [(0.0, end, 0.0)]
    spans, t = [], 0.0
    for entry in score["form"]:
        s = score["sections"][entry["section"]]
        spans.append((s["start"], s["end"], t))
        t += s["end"] - s["start"]
    return spans


def write_midi(score: dict, path: str, full_form: bool = False, bpm: float | None = None) -> None:
    tempo = score.get("tempo") or {"min": 100, "max": 100}
    unit = {"eighth": 0.5, "quarter": 1.0, "half": 2.0}.get(tempo.get("beatUnit"), 1.0) * (1.5 if tempo.get("dotted") else 1)
    bpm = bpm or (tempo["min"] + tempo["max"]) / 2 * unit  # in quarter notes per minute
    tracks = [_track([(0, b"\xff\x51\x03" + struct.pack(">I", round(60_000_000 / bpm))[1:])])]
    for ch, (part, notes) in enumerate(score["parts"].items()):
        events = [(0, bytes([0xC0 | ch, PROGRAMS.get(part, 0)])),
                  (0, b"\xff\x03" + _varlen(len(part)) + part.encode())]
        for a, b, offset in performance(score, full_form):
            for n in notes:
                if a <= n["start"] < b and not n.get("rest"):
                    on = round((n["start"] - a + offset) * PPQ)
                    off = round((n["start"] - a + offset + n["duration"]) * PPQ) - 10
                    events += [(on, bytes([0x90 | ch, n["midi"], 80])), (off, bytes([0x80 | ch, n["midi"], 0]))]
        tracks.append(_track(events))
    with open(path, "wb") as f:
        f.write(b"MThd" + struct.pack(">IHHH", 6, 1, len(tracks), PPQ) + b"".join(tracks))
