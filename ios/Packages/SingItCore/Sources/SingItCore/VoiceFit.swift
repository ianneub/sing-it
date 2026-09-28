import Foundation

/// The span a singer is comfortable in, as MIDI note numbers.
public struct VoiceRange: Codable, Sendable, Equatable {
    public var low: Double
    public var high: Double

    public init(low: Double, high: Double) {
        self.low = min(low, high)
        self.high = max(low, high)
    }

    /// From pitched-frame counts per semitone (`SessionSummary.pitchCountRange`): the 10th
    /// to 90th percentile, so the odd strained note or detector slip doesn't widen it.
    public static func from(pitchCounts counts: [Int], minimumFrames: Int = 1500) -> VoiceRange? {
        let total = counts.reduce(0, +)
        guard total >= minimumFrames else { return nil }
        func percentile(_ p: Double) -> Double {
            var running = 0
            for (i, c) in counts.enumerated() {
                running += c
                if Double(running) >= p * Double(total) {
                    return Double(SessionSummary.pitchCountRange.lowerBound + i)
                }
            }
            return Double(SessionSummary.pitchCountRange.upperBound)
        }
        return VoiceRange(low: percentile(0.1), high: percentile(0.9))
    }

    public var text: String { "\(NoteName.name(Int(low.rounded())))–\(NoteName.name(Int(high.rounded())))" }
}

/// How well a part, sung in a given octave, sits in a singer's range.
public struct VoiceFit: Sendable, Identifiable {
    public let part: Part
    /// Octaves from written (-1: an octave down).
    public let octaveShift: Int
    /// Share of the singing time inside the range.
    public let inRange: Double
    public let lowest: Int
    public let highest: Int
    /// Notes above or below the range (counting every verse).
    public let notesTooHigh: Int
    public let notesTooLow: Int

    public var id: String { "\(part.rawValue)\(octaveShift)" }

    /// e.g. "Melody, an octave down"
    public var label: String {
        let octave: String
        switch octaveShift {
        case 0: octave = "as written"
        case -1: octave = "an octave down"
        case 1: octave = "an octave up"
        default: octave = "\(abs(octaveShift)) octaves \(octaveShift < 0 ? "down" : "up")"
        }
        return "\(part.displayName), \(octave)"
    }

    /// Each voice in the octaves people actually sing it: as written, a man taking the
    /// melody an octave down (or two, for a low voice), a woman taking tenor or bass an
    /// octave up. (Alto an octave down fits many men's ranges on paper, but nobody sings
    /// it.) Best fit first; ties go to singing as written.
    public static func options(for hymn: Hymn, range: VoiceRange) -> [VoiceFit] {
        let candidates: [(Part, Int)] = [
            (.melody, 0), (.melody, -1), (.melody, -2), (.alto, 0),
            (.tenor, 0), (.tenor, 1), (.bass, 0), (.bass, 1),
        ]
        return candidates.map { part, shift in
            let performance = Performance(hymn: hymn, part: part, octaveShift: shift)
            var inside = 0.0, total = 0.0, high = 0, low = 0
            var lo = Int.max, hi = Int.min
            for note in performance.notes {
                guard let midi = note.midi else { continue }
                total += note.duration
                lo = min(lo, midi)
                hi = max(hi, midi)
                if Double(midi) > range.high + 0.5 { high += 1 }
                else if Double(midi) < range.low - 0.5 { low += 1 }
                else { inside += note.duration }
            }
            return VoiceFit(part: part, octaveShift: shift, inRange: total > 0 ? inside / total : 0,
                            lowest: lo, highest: hi, notesTooHigh: high, notesTooLow: low)
        }
        .sorted { a, b in
            if abs(a.inRange - b.inRange) > 0.005 { return a.inRange > b.inRange }
            return abs(a.octaveShift) < abs(b.octaveShift)
        }
    }
}
