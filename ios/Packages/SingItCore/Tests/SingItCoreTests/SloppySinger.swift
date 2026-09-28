import Foundation
@testable import SingItCore

/// Deterministic random numbers (SplitMix64) so simulated singers are repeatable.
struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func normal() -> Double {  // Box-Muller
        let u = Double.random(in: 1e-9..<1, using: &self), v = Double.random(in: 0..<1, using: &self)
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
    }
}

/// An untrained singer, modelled on real recordings: an octave off, each note off by
/// about a semitone and a half plus slow drift, uneven tempo with pauses at phrase ends,
/// a third of pitch frames lost, and syllable starts that are only sometimes audible.
/// Each frame carries the true score beat, a pitch (or nil), a loudness and dt.
struct SloppySinger {
    var bpm = 90.0
    var octave = -12.0
    var noteErrorCents = 150.0
    var tempoJitter = 0.25
    var dropout = 0.33
    var audibleOnsets = 0.6
    var seed: UInt64 = 1

    func frames(_ performance: Performance, to: Double? = nil, dt: Double = 0.02)
        -> [(pitch: PitchEstimate?, level: Double, dt: Double, beat: Double)] {
        var rng = SeededRandom(seed: seed)
        var out: [(pitch: PitchEstimate?, level: Double, dt: Double, beat: Double)] = []
        var drift = 0.0
        let end = min(to ?? performance.totalBeats, performance.totalBeats)
        for (i, note) in performance.notes.enumerated() where note.start < end {
            // How long this singer holds the note: uneven, longer before a rest or at a pass end.
            var seconds = note.duration * 60 / bpm * max(0.5, 1 + tempoJitter * rng.normal())
            let nextIsRest = i + 1 < performance.notes.count && performance.notes[i + 1].isRest
            let passEnds = performance.passes.contains { abs($0.end - note.end) < 1e-6 }
            if (nextIsRest || passEnds) && Double.random(in: 0..<1, using: &rng) < 0.5 { seconds += 0.4 }
            let count = max(1, Int(seconds / dt))
            drift = 0.9 * drift + 0.3 * rng.normal()               // slow wander, semitones
            let error = noteErrorCents / 100 * rng.normal() + drift  // this note's miss
            let gap = Double.random(in: 0..<1, using: &rng) < audibleOnsets ? 3 : 0
            for k in 0..<count {
                let beat = note.start + note.duration * Double(k) / Double(count)
                let t = Double(out.count) * dt
                guard let midi = note.midi, k >= gap || note.isRest == false && gap == 0 else {
                    out.append((nil, -60, dt, beat)); continue
                }
                if k < gap { out.append((nil, -60, dt, beat)); continue }
                if Double.random(in: 0..<1, using: &rng) < dropout {
                    out.append((nil, -35, dt, beat)); continue
                }
                let sung = Double(midi) + octave + error + 0.25 * sin(2 * .pi * 5.5 * t)
                out.append((PitchEstimate(midi: sung, clarity: 0.7), -30, dt, beat))
            }
        }
        return out
    }
}
