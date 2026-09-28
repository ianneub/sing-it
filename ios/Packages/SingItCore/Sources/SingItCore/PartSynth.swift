import Foundation

/// Renders one part as a soft organ-like tone on an accompaniment recording's timeline,
/// so the app can play just the singer's line (or add it over the accompaniment): sample 0
/// is time 0 of the recording, and each note sounds when the recording plays that beat.
public enum PartSynth {
    /// Relative strengths of the first few harmonics: a mellow flute-stop sound.
    static let harmonics: [Float] = [1, 0.45, 0.22, 0.1]
    static let gain: Float = 0.2

    /// One cycle of the tone, looked up by phase: far cheaper than summing sines per sample.
    static let wavetable: [Float] = {
        let size = 2048
        return (0..<size).map { i in
            let phase = 2 * Double.pi * Double(i) / Double(size)
            return harmonics.enumerated().reduce(Float(0)) { $0 + $1.element * Float(sin(phase * Double($1.offset + 1))) }
        }
    }()

    public static func render(_ performance: Performance, beatMap: BeatMap, sampleRate: Double) -> [Float] {
        var out = [Float](repeating: 0, count: Int(beatMap.duration * sampleRate))
        let attack = 0.015, release = 0.05
        for note in performance.notes {
            guard let midi = note.midi else { continue }
            let t0 = beatMap.time(atBeat: note.start)
            // Leave a hair of space before the next note so repeated notes are heard as two.
            let t1 = max(t0 + 0.05, beatMap.time(atBeat: note.end) - 0.03)
            let first = max(0, Int(t0 * sampleRate))
            let last = min(out.count, Int((t1 + release) * sampleRate))
            guard first < last else { continue }
            let table = wavetable
            let step = Double(table.count) * 440 * pow(2, (Double(midi) - 69) / 12) / sampleRate
            var phase = 0.0
            for i in first..<last {
                let t = Double(i) / sampleRate
                let envelope: Double
                if t < t0 + attack { envelope = (t - t0) / attack }
                else if t < t1 { envelope = 1 }
                else { envelope = max(0, 1 - (t - t1) / release) }
                out[i] += gain * Float(envelope) * table[Int(phase)]
                phase += step
                if phase >= Double(table.count) { phase -= Double(table.count) }
            }
        }
        return out
    }
}
