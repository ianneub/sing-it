import Foundation

/// How closely the sung pitch matched one target note.
public struct NoteResult: Sendable, Equatable {
    public var frames = 0
    public var inTuneFrames = 0
    public var octaveFrames = 0
    public var sumCents = 0.0
    public var sumAbsCents = 0.0

    /// Share of pitched frames within tolerance, 0...1.
    public var accuracy: Double { frames > 0 ? Double(inTuneFrames) / Double(frames) : 0 }
    /// Average offset in cents; positive = sharp.
    public var meanCents: Double { frames > 0 ? sumCents / Double(frames) : 0 }
    public var meanAbsCents: Double { frames > 0 ? sumAbsCents / Double(frames) : 0 }
}

/// Where a sung pitch sits relative to a note, after choosing the nearest acceptable target.
public struct PitchComparison: Sendable, Equatable {
    public let target: Int
    /// Offset folded into ±600 cents; positive = sharp.
    public let cents: Double
    /// Right note name, wrong octave.
    public let octaveOff: Bool
    /// Whole octaves between the sung pitch and the target (positive = above).
    public let octaves: Int

    /// With `anyOctave`, the nearest target is judged by note name, ignoring octaves.
    public init(sungMidi: Double, targets: [Int], anyOctave: Bool = false) {
        func distance(_ target: Int) -> Double {
            let d = sungMidi - Double(target)
            return anyOctave ? abs(d - 12 * (d / 12).rounded()) : abs(d)
        }
        let nearest = targets.min { distance($0) < distance($1) } ?? 60
        var cents = (sungMidi - Double(nearest)) * 100
        var octaves = 0
        while cents > 600 { cents -= 1200; octaves += 1 }
        while cents < -600 { cents += 1200; octaves -= 1 }
        self.target = nearest
        self.cents = cents
        self.octaveOff = octaves != 0
        self.octaves = octaves
    }
}

/// Keeps per-note results and the running score for one session.
public struct Scorekeeper: Sendable {
    /// Cents either side of the target that count as in tune.
    public var tolerance: Double
    /// Count the right note in any octave as in tune (men often sing a part an octave down).
    public var anyOctave = true
    /// Notes need this many pitched frames (20 ms each) before they count.
    public var minimumFrames = 5
    public private(set) var results: [Int: NoteResult] = [:]
    public private(set) var streak = 0
    public private(set) var bestStreak = 0
    /// In-tune frames per voice, when any part counts (which part the singer found).
    public private(set) var partHits: [String: Int] = [:]
    /// Pitched frames per note per octave relative to the target (0: the target's octave,
    /// -1: an octave below).
    public private(set) var noteOctaves: [Int: [Int: Int]] = [:]
    private var lastScoredNote: Int?

    public init(tolerance: Double = 50) {
        self.tolerance = tolerance
    }

    public func isInTune(_ comparison: PitchComparison) -> Bool {
        (anyOctave || !comparison.octaveOff) && abs(comparison.cents) <= tolerance
    }

    public mutating func record(noteIndex: Int, comparison: PitchComparison, part: String? = nil) {
        if let part, isInTune(comparison) { partHits[part, default: 0] += 1 }
        noteOctaves[noteIndex, default: [:]][comparison.octaves, default: 0] += 1
        if let last = lastScoredNote, last != noteIndex { closeNote(last) }
        lastScoredNote = noteIndex
        var r = results[noteIndex] ?? NoteResult()
        r.frames += 1
        if isInTune(comparison) { r.inTuneFrames += 1 }
        if comparison.octaveOff { r.octaveFrames += 1 }
        r.sumCents += comparison.cents
        r.sumAbsCents += abs(comparison.cents)
        results[noteIndex] = r
    }

    /// A note counts toward the streak when at least 70% of it was in tune.
    private mutating func closeNote(_ index: Int) {
        guard let r = results[index], r.frames >= minimumFrames else { return }
        if r.accuracy >= 0.7 {
            streak += 1
            bestStreak = max(bestStreak, streak)
        } else {
            streak = 0
        }
    }

    /// 0...100, weighting each scored note by its length.
    public func score(in performance: Performance) -> Double {
        var weighted = 0.0, total = 0.0
        for (index, r) in results where r.frames >= minimumFrames {
            let weight = performance.notes[index].duration
            weighted += r.accuracy * weight
            total += weight
        }
        return total > 0 ? 100 * weighted / total : 0
    }

    public var scoredNotes: Int { results.values.filter { $0.frames >= minimumFrames }.count }

    /// The octave (relative to the target) most of a note was sung in.
    public func octave(ofNote index: Int) -> Int? {
        guard let counts = noteOctaves[index], (results[index]?.frames ?? 0) >= minimumFrames else { return nil }
        return counts.max { $0.value < $1.value }?.key
    }
}
