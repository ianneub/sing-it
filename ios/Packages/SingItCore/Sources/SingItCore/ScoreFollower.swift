import Foundation

/// Tracks where the singer is in a performance from their pitch alone, so the app follows
/// the singer rather than the organ (a headset mic barely hears the organ).
///
/// A grid Bayes filter over beat position (`binsPerBeat` bins per quarter note):
///  * predict: probability mass advances at the current tempo, with a little diffusion;
///    at fermatas and at the end of each pass (a breath between verses) some mass waits.
///    A small share is spread over the beats around the estimate, so a follower that has
///    drifted can be pulled back by what the singer sings next;
///  * update: each bin is weighted by how well the sung pitch fits the note there. The
///    pitch model is deliberately wide, so an off-key singer is still followed.
/// Nothing advances until the singer's first pitched sound (the organ introduction).
/// Work is limited to the window of bins that hold probability.
public final class ScoreFollower {
    public let performance: Performance
    public let binsPerBeat = 16
    /// Standard deviation of the sung pitch around the target, in semitones.
    public var pitchSigma = 2.0
    /// Match notes by name in any octave (a singer an octave down fits just as well).
    public var anyOctave = true
    /// Likelihood of any pitch at all under a note (a wrong note is still possible there).
    public var wrongNoteLikelihood = 0.3
    /// Consecutive 20 ms frames are far from independent; each frame's evidence is raised
    /// to this power so a held wrong note doesn't count as dozens of separate witnesses.
    public var evidenceWeight = 0.4
    /// Share of probability re-spread per second over the beats around the estimate
    /// (mostly ahead: a follower lags far more often than a singer goes back). Off by
    /// default: with untrained singers it caused more jumps than it fixed. The singer
    /// tapping a lyric line is the way back when lost.
    public var recoveryRate = 0.0
    /// How fast the position may wander from the steady tempo: diffusion per second, in
    /// bins². 3 suits singing with an organ keeping time; 12 a singer alone with uneven
    /// timing (see `SingingSession.steadyTempo`).
    public var diffusion = 3.0
    /// Candidates further than this many beats from the estimate are dropped each step
    /// (0 = off, the default). Tested and rejected: when the estimate is behind, it drops
    /// the true position and never recovers. Kept for experiments.
    public var reach = 0.0
    /// Whether the tempo adapts to how fast the estimate moves, and how far outside the
    /// hymn's marked range it may go (0.1 = 10% below the slowest to 10% above the fastest).
    /// Adapting from its own estimate can feed on itself (a follower that lags concludes the
    /// singer is slow), so it stays near the marked range, where organists play.
    public var adaptsTempo = true
    public var tempoMargin = 0.1 {
        didSet { tempoRange = Self.range(performance.hymn.quarterBPMRange, margin: tempoMargin) }
    }
    /// When the singer starts a new sound (an onset), how likely that is anywhere other
    /// than at the start of a note, relative to at one. Onsets are a timing clue that
    /// doesn't depend on singing in tune.
    public var onsetElsewhere = 0.6
    public var recoveryBack = 1.5
    public var recoveryAhead = 6.0
    public private(set) var tempo: Double
    public private(set) var started = false
    /// Sum over pitched frames of log p(pitch | everything before); compares parts.
    public private(set) var logEvidence = 0.0
    public private(set) var pitchedFrames = 0
    public private(set) var position = 0.0
    public private(set) var confidence = 1.0

    private var prob: [Double]
    private var next: [Double]
    private var lo = 0, hi = 0               // active window, inclusive
    private let binNote: [Int32]             // note index per bin
    private let stay: [Double]               // per-bin chance of not advancing in a 20 ms step
    private let nearNoteStart: [Bool]        // an onset is expected in this bin
    private var tempoRange: ClosedRange<Double>
    private var noteLikelihood: [Double]
    private var tempoAnchor: (time: Double, beat: Double)?
    private var clock = 0.0

    public init(performance: Performance, tempo: Double? = nil, startBeat: Double = 0) {
        self.performance = performance
        let range = performance.hymn.quarterBPMRange
        self.tempo = tempo ?? (range.lowerBound + range.upperBound) / 2
        self.tempoRange = Self.range(range, margin: 0.1)

        let bpb = Double(binsPerBeat)
        let count = max(1, Int((performance.totalBeats * bpb).rounded(.up)))
        var binNote = [Int32](repeating: -1, count: count)
        var stay = [Double](repeating: 0, count: count)
        for (i, note) in performance.notes.enumerated() {
            let a = Int((note.start * bpb).rounded()), b = Int((note.end * bpb).rounded())
            for bin in max(0, a)..<min(count, max(a + 1, b)) {
                binNote[bin] = Int32(i)
                if note.fermata { stay[bin] = 0.5 }
            }
        }
        // Onsets land just after a sung note starts (a little early is fine too).
        var nearNoteStart = [Bool](repeating: false, count: count)
        for note in performance.notes where !note.isRest {
            let a = Int(((note.start - 0.1) * bpb).rounded()), b = Int(((note.start + 0.35) * bpb).rounded())
            for bin in max(0, a)..<min(count, max(a + 1, b)) { nearNoteStart[bin] = true }
        }
        self.nearNoteStart = nearNoteStart
        // A pause may come before a new verse (a breath, or the organist's gap), but not
        // between a verse and its chorus: the accompaniment runs straight on.
        for (pass, next) in zip(performance.passes, performance.passes.dropFirst()) where next.verse != nil {
            let end = Int((pass.end * bpb).rounded())
            for bin in max(0, end - binsPerBeat / 2)..<min(count, end) { stay[bin] = max(stay[bin], 0.6) }
        }
        self.binNote = binNote
        self.stay = stay
        self.prob = [Double](repeating: 0, count: count)
        self.next = prob
        self.noteLikelihood = [Double](repeating: 1, count: performance.notes.count)
        jump(to: startBeat)
    }

    /// Restart the estimate at `beat` (e.g. the user picked a verse or tapped a line).
    public func jump(to beat: Double) {
        for i in lo...hi { prob[i] = 0 }
        let bin = min(max(0, Int((beat * Double(binsPerBeat)).rounded())), prob.count - 1)
        prob[bin] = 1
        lo = bin
        hi = bin
        position = Double(bin) / Double(binsPerBeat)
        confidence = 1
        tempoAnchor = nil
    }

    /// Advance by `dt` seconds and take one pitch observation (nil = silence or noise).
    /// `onset` says the singer just started a new sound (a syllable).
    public func update(dt: Double, pitch: PitchEstimate?, onset: Bool = false) {
        clock += dt
        if !started {
            guard pitch != nil else { return }
            started = true
        }
        predict(dt: dt)
        observe(pitch)
        if onset { observeOnset() }
        summarise()
        adaptTempo(pitched: pitch != nil)
    }

    private func predict(dt: Double) {
        let n = prob.count
        let step = dt * tempo / 60 * Double(binsPerBeat)
        let whole = Int(step), frac = step - Double(whole)
        let stayScale = dt / 0.02
        let newHi = min(n - 1, hi + whole + 2)
        for i in lo...newHi { next[i] = 0 }
        for i in lo...hi where prob[i] > 0 {
            let s = min(0.95, stay[i] * stayScale)
            let moving = prob[i] * (1 - s)
            next[i] += prob[i] * s
            next[min(n - 1, i + whole)] += moving * (1 - frac)
            next[min(n - 1, i + whole + 1)] += moving * frac
        }
        // Diffusion absorbs tempo wobble (a [k, 1-2k, k] kernel adds 2k bins² of variance).
        let k = min(0.25, diffusion / 2 * dt)
        let a = max(0, lo - 1), b = min(n - 1, newHi + 1)
        for i in a...b {
            let here = i >= lo && i <= newHi ? next[i] : 0
            let left = i - 1 >= lo && i - 1 <= newHi ? next[i - 1] : 0
            let right = i + 1 >= lo && i + 1 <= newHi ? next[i + 1] : 0
            let keep = here * (1 - (i == 0 || i == n - 1 ? k : 2 * k))
            prob[i] = keep + (left + right) * k
        }
        lo = a
        hi = b

        // Recovery: spread a little mass evenly around the current estimate.
        let share = min(0.5, recoveryRate * dt)
        let center = Int(position * Double(binsPerBeat))
        guard share > 0 else { return }
        let r0 = max(0, center - Int(recoveryBack * Double(binsPerBeat)))
        let r1 = min(n - 1, center + Int(recoveryAhead * Double(binsPerBeat)))
        for i in lo...hi { prob[i] *= 1 - share }
        let each = share / Double(r1 - r0 + 1)
        for i in r0...r1 { prob[i] += each }
        lo = min(lo, r0)
        hi = max(hi, r1)
    }

    private func observe(_ pitch: PitchEstimate?) {
        let restLikelihood: Double
        let firstNote = Int(binNote[lo]), lastNote = Int(binNote[hi])
        let noteRange = (firstNote >= 0 ? firstNote : 0)...(lastNote >= 0 ? lastNote : performance.notes.count - 1)
        if let pitch {
            let p = pitch.midi
            let twoSigma2 = 2 * pitchSigma * pitchSigma
            let weight = evidenceWeight * max(0.3, pitch.clarity)  // doubtful frames count less
            let restVoiced = pow(0.15, weight)
            for i in noteRange {
                let note = performance.notes[i]
                guard !note.isRest else { noteLikelihood[i] = restVoiced; continue }
                var best = 0.0
                for m in note.targets {
                    let d = p - Double(m)
                    if anyOctave {
                        let folded = d - 12 * (d / 12).rounded()
                        best = max(best, exp(-folded * folded / twoSigma2))
                    } else {
                        let octave = min(abs(d - 12), abs(d + 12))
                        best = max(best, exp(-d * d / twoSigma2) + 0.3 * exp(-octave * octave / twoSigma2))
                    }
                }
                noteLikelihood[i] = pow(wrongNoteLikelihood + best, weight)
            }
            restLikelihood = restVoiced
        } else {
            // Silence says little: a breath, quiet singing or a missed frame look the same
            // as a rest, so it mustn't pull the estimate toward the next rest.
            for i in noteRange { noteLikelihood[i] = 1 }
            restLikelihood = 1
        }
        var total = 0.0
        for i in lo...hi {
            let note = Int(binNote[i])
            prob[i] *= note >= 0 ? noteLikelihood[note] : restLikelihood
            total += prob[i]
        }
        if pitch != nil {
            logEvidence += log(max(total, 1e-300))
            pitchedFrames += 1
        }
        guard total > 0 else { jump(to: position); return }
        var scale = 1 / total
        if reach > 0 {
            let r0 = max(lo, Int((position - reach) * Double(binsPerBeat)))
            let r1 = min(hi, Int((position + reach) * Double(binsPerBeat)))
            if r0 <= r1 && (r0 > lo || r1 < hi) {
                for i in lo..<r0 { prob[i] = 0 }
                if r1 < hi { for i in (r1 + 1)...hi { prob[i] = 0 } }
                lo = r0
                hi = r1
                var kept = 0.0
                for i in lo...hi { kept += prob[i] }
                guard kept > 0 else { jump(to: position); return }
                scale = 1 / kept
            }
        }
        for i in lo...hi { prob[i] *= scale }
        // Drop negligible tails from the window.
        while lo < hi && prob[lo] < 1e-12 { prob[lo] = 0; lo += 1 }
        while hi > lo && prob[hi] < 1e-12 { prob[hi] = 0; hi -= 1 }
    }

    private func observeOnset() {
        var total = 0.0
        for i in lo...hi {
            if !nearNoteStart[i] { prob[i] *= onsetElsewhere }
            total += prob[i]
        }
        guard total > 0 else { return }
        for i in lo...hi { prob[i] /= total }
    }

    /// Position = posterior mean within a beat of the peak; confidence = mass within half a beat.
    private func summarise() {
        var peak = lo
        for i in lo...hi where prob[i] > prob[peak] { peak = i }
        let a = max(lo, peak - binsPerBeat), b = min(hi, peak + binsPerBeat)
        var mass = 0.0, sum = 0.0
        for i in a...b { mass += prob[i]; sum += prob[i] * Double(i) }
        position = (mass > 0 ? sum / mass : Double(peak)) / Double(binsPerBeat)
        let center = Int((position * Double(binsPerBeat)).rounded())
        var near = 0.0
        for i in max(lo, center - binsPerBeat / 2)...max(lo, min(hi, center + binsPerBeat / 2)) { near += prob[i] }
        confidence = near
    }

    private static func range(_ marked: ClosedRange<Double>, margin: Double) -> ClosedRange<Double> {
        (marked.lowerBound * (1 - margin))...(marked.upperBound * (1 + margin))
    }

    /// Nudge the tempo toward how fast the confident position has actually moved.
    private func adaptTempo(pitched: Bool) {
        guard adaptsTempo, pitched, confidence > 0.6 else { return }
        let beat = position
        guard let anchor = tempoAnchor else { tempoAnchor = (clock, beat); return }
        let elapsed = clock - anchor.time
        guard elapsed >= 2 else { return }
        let from = min(max(0, Int(anchor.beat * Double(binsPerBeat))), stay.count)
        let to = min(max(from, Int(beat * Double(binsPerBeat))), stay.count)
        let heldUp = stay[from..<to].contains { $0 > 0 }
        if !heldUp && beat > anchor.beat {
            let measured = (beat - anchor.beat) / elapsed * 60
            let clamped = min(max(measured, tempoRange.lowerBound), tempoRange.upperBound)
            tempo = 0.8 * tempo + 0.2 * clamped
        }
        tempoAnchor = (clock, beat)
    }
}
