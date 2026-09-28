import Foundation

public enum PitchHint: String, Sendable {
    case waiting    // nothing sung yet (the organ introduction)
    case intro      // the app's accompaniment is playing the introduction
    case silent     // no clear pitch right now
    case rest       // the part rests here
    case higher     // sing higher
    case lower      // sing lower
    case onPitch
    case octave     // right note, wrong octave (a miss: the singer is held to the octave)
    case octaveSlip // right note, out of the singer's chosen octave (still counts)
}

public struct LiveState: Sendable {
    public var part: Part
    /// True while Auto is still deciding which part the singer is on.
    public var partIsGuess: Bool
    public var started: Bool
    public var position: Double
    public var confidence: Double
    public var tempo: Double
    public var sungMidi: Double?
    /// The sung pitch moved by whole octaves to sit next to the target (for drawing),
    /// when any octave counts.
    public var sungMidiNearTarget: Double?
    public var noteIndex: Int?
    public var comparison: PitchComparison?
    public var hint: PitchHint
    public var score: Double
    public var streak: Int
    public var scoredNotes: Int
}

public struct TracePoint: Sendable {
    public let beat: Double
    /// Sung pitch, moved by whole octaves next to the target when any octave counts.
    public let midi: Double
    /// Counted, but out of the octave the singer chose to sing in.
    public var slipped = false
    /// nil when the part is resting.
    public let inTune: Bool?
}

/// Everything that happens while singing one hymn: audio in, live feedback out.
/// `process(_:)` is called from the audio thread; the other members from the UI.
public final class SingingSession: @unchecked Sendable {
    public let hymn: Hymn
    public let sampleRate: Double
    public let tolerance: Double
    public let anyOctave: Bool
    /// True when an organ (or congregation) keeps a steady tempo; false for singing alone.
    public let steadyTempo: Bool
    /// Octaves the singer sings the part from where it's written (-1: an octave down).
    public let octaveShift: Int
    /// The singer chose that octave: point out slips from it, even when any octave counts.
    public let coachOctave: Bool

    private let detector: PitchDetector
    private let frameLength: Int
    private let hop: Int
    private var buffer: [Float] = []
    /// Index (since the session began) of `buffer[0]`.
    private var consumed = 0
    /// When the app plays the accompaniment, the beat of a given sample is known exactly.
    private var musicClock: (sample: Int, beat: Double, rate: Double)?
    /// The known beat of the latest frame, when the position comes from the music.
    private var musicBeat: Double?
    private var followers: [Part: ScoreFollower]
    private var scorekeepers: [Part: Scorekeeper]
    private var chosen: Part
    /// Any part: the merged chord line used for scoring and display, while the four voice
    /// followers track position; the one that has matched the singer best lately leads.
    private let chordPerformance: Performance?
    private var leading: Part = .soprano
    private var recentEvidence: [Part: Double] = [:]
    private var lastEvidence: [Part: Double] = [:]
    private var autoDetecting: Bool
    private var trace: [TracePoint] = []
    private var recentCents: [Double] = []
    private var recentNote: Int?
    private var lastPitch: PitchEstimate?
    private var onsets = OnsetDetector()
    /// The position shown and scored: glides with the tempo and eases toward the
    /// follower's estimate, so the display doesn't jitter or bounce.
    private var shown = 0.0
    private var offTrackFor = 0.0
    /// Pitched frames per sung semitone (MIDI 24...84), for learning the singer's range.
    private var pitchCounts = [Int](repeating: 0, count: SessionSummary.pitchCountRange.count)
    /// Practice mode: how far behind the music the singer sings (seconds), measured from
    /// recent singing, and the samples it's measured from.
    public private(set) var musicLag = 0.0
    private var lagSamples: [(beat: Double, midi: Double)] = []
    private var framesSinceLagCheck = 0
    private let lock = NSLock()

    /// `part` nil means Auto: follow all four and settle on the one the singer is on.
    /// `anyOctave`: the right note in any octave counts (men often sing an octave down).
    /// `steadyTempo`: an organ keeps time; false lets the position follow uneven timing.
    /// `octaveShift`: which octave the singer means to sing the part in; with `anyOctave`
    /// off, other octaves count as misses. `coachOctave`: they chose it, so point out slips
    /// even when other octaves still count.
    public init(hymn: Hymn, part: Part?, startVerse: Int = 1, tolerance: Double = 50, anyOctave: Bool = true,
                steadyTempo: Bool = true, octaveShift: Int = 0, coachOctave: Bool = false, sampleRate: Double = 16_000) {
        self.hymn = hymn
        self.sampleRate = sampleRate
        self.tolerance = tolerance
        self.anyOctave = anyOctave
        self.steadyTempo = steadyTempo
        self.octaveShift = part == .anyPart ? 0 : octaveShift
        self.coachOctave = coachOctave && part != nil && part != .anyPart
        self.detector = PitchDetector(sampleRate: sampleRate)
        self.frameLength = Int(sampleRate * 0.064)       // 64 ms window
        self.hop = Int(sampleRate * 0.02)                // 20 ms step
        let chord = part == .anyPart
        let parts = chord ? Part.voices : part.map { [$0] } ?? Part.voices
        var followers: [Part: ScoreFollower] = [:]
        var scorekeepers: [Part: Scorekeeper] = [:]
        for p in parts {
            let performance = Performance(hymn: hymn, part: p, octaveShift: chord ? 0 : octaveShift)
            let follower = ScoreFollower(performance: performance, startBeat: performance.start(ofVerse: startVerse))
            // Following always matches notes in any octave, so a singer who slips out of
            // their octave isn't also lost; only scoring holds them to it.
            follower.anyOctave = true
            follower.diffusion = steadyTempo ? 3 : 12
            followers[p] = follower
            var keeper = Scorekeeper(tolerance: tolerance)
            keeper.anyOctave = anyOctave
            scorekeepers[chord ? .anyPart : p] = keeper
        }
        self.followers = followers
        self.scorekeepers = scorekeepers
        self.chordPerformance = chord ? Performance(hymn: hymn, part: .anyPart) : nil
        self.chosen = part ?? .soprano
        self.autoDetecting = part == nil
        self.shown = followers.values.first!.position
    }

    public var part: Part { lock.withLock { chosen } }
    /// The chosen part's follower, for tuning experiments only.
    var followerForTuning: ScoreFollower { leader }
    public var performance: Performance { lock.withLock { shownPerformance } }

    /// The follower whose position is shown and scored.
    private var leader: ScoreFollower { followers[chordPerformance == nil ? chosen : leading]! }
    /// What the singer is scored against and sees.
    private var shownPerformance: Performance { chordPerformance ?? leader.performance }

    /// Practice with the app's accompaniment: the next sample passed to `process(_:)` was
    /// captured while the music played `beat`, moving at `rate` beats per second. Call it
    /// before each block; the position then comes from the music instead of the follower.
    public func setMusicClock(beat: Double, rate: Double) {
        lock.withLock { musicClock = (consumed + buffer.count, beat, rate) }
    }

    /// Feed mono samples at `sampleRate`, any block size.
    public func process(_ samples: [Float]) {
        buffer += samples
        while buffer.count >= frameLength {
            // With the music clock, the beat at the middle of this frame.
            let known = lock.withLock { musicClock }.map { clock in
                clock.beat + Double(consumed + frameLength / 2 - clock.sample) / sampleRate * clock.rate
            }
            let frame = Array(buffer[0..<frameLength])
            let pitch = detector.estimate(frame)
            // Level of the newest 20 ms, for spotting syllable starts.
            var energy: Float = 0
            for x in frame[(frameLength - hop)...] { energy += x * x }
            let level = 10 * log10(Double(energy / Float(hop)) + 1e-12)
            process(pitch: pitch, dt: Double(hop) / sampleRate, level: level, knownBeat: known)
            buffer.removeFirst(hop)
            consumed += hop
        }
    }

    /// Whether singing is under way: from the music's position when it's playing,
    /// otherwise once the follower has heard the first note.
    private func isSinging(_ follower: ScoreFollower) -> Bool {
        musicBeat.map { $0 >= 0 } ?? follower.started
    }

    /// Whether to trust the position enough to score.
    private func trusted(_ follower: ScoreFollower) -> Bool {
        isSinging(follower) && (musicBeat != nil || follower.confidence > 0.3)
    }

    /// One analysis step: `pitch` is what was heard over the last `dt` seconds, and
    /// `level` the loudness in dB (optional; it sharpens syllable detection).
    /// `knownBeat`: the position when it comes from the app's accompaniment.
    public func process(pitch: PitchEstimate?, dt: Double, level: Double? = nil, knownBeat: Double? = nil) {
        lock.lock()
        defer { lock.unlock() }
        lastPitch = pitch
        musicBeat = knownBeat
        let onset = onsets.step(voiced: pitch != nil, level: level, dt: dt)
        for follower in followers.values { follower.update(dt: dt, pitch: pitch, onset: onset) }
        if autoDetecting { decidePart() }
        if chordPerformance != nil { pickLeader() }
        if let knownBeat {
            if let pitch, knownBeat >= 0 { noteLag(beat: knownBeat, midi: pitch.midi) }
            shown = knownBeat - musicLag * (musicClock?.rate ?? 0)
        } else {
            glide(dt: dt)
        }
        if let pitch, isSinging(leader) {
            let bin = Int(pitch.midi.rounded()) - SessionSummary.pitchCountRange.lowerBound
            if pitchCounts.indices.contains(bin) { pitchCounts[bin] += 1 }
        }
        if let chord = chordPerformance {
            let follower = leader
            if trusted(follower), let pitch, let index = chord.noteIndex(at: shown),
               !chord.notes[index].isRest {
                let note = chord.notes[index]
                let comparison = PitchComparison(sungMidi: pitch.midi, targets: note.targets, anyOctave: anyOctave)
                let voice = note.targetParts[note.targets.firstIndex(of: comparison.target) ?? 0]
                scorekeepers[.anyPart]!.record(noteIndex: index, comparison: comparison, part: voice)
            }
            recordTrace(pitch)
            return
        }
        for (part, follower) in followers where trusted(follower) {
            let position = part == chosen || musicBeat != nil ? shown : follower.position
            guard let pitch, let index = follower.performance.noteIndex(at: position) else { continue }
            let note = follower.performance.notes[index]
            guard !note.isRest else { continue }
            let comparison = PitchComparison(sungMidi: pitch.midi, targets: note.targets, anyOctave: anyOctave)
            let voice = note.targetParts.isEmpty ? nil : note.targetParts[note.targets.firstIndex(of: comparison.target) ?? 0]
            scorekeepers[part]!.record(noteIndex: index, comparison: comparison, part: voice)
        }
        recordTrace(pitch)
    }

    /// Practice mode: people sing a little behind what they hear, and the latency iOS
    /// reports isn't exact. Every two seconds, find the lag (-0.2 to 0.8 s) that best lines
    /// the last 30 s of singing up with the notes, by note name, and ease toward it.
    private func noteLag(beat: Double, midi: Double) {
        lagSamples.append((beat, midi))
        if lagSamples.count > 1500 { lagSamples.removeFirst(lagSamples.count - 1500) }
        framesSinceLagCheck += 1
        guard framesSinceLagCheck >= 100, lagSamples.count >= 300, let rate = musicClock?.rate else { return }
        framesSinceLagCheck = 0
        let performance = shownPerformance
        func matchRate(_ lag: Double) -> Double {
            var hits = 0, total = 0
            for sample in lagSamples {
                guard let i = performance.noteIndex(at: sample.beat - lag * rate), !performance.notes[i].isRest else { continue }
                total += 1
                let off = performance.notes[i].targets.map { t -> Double in
                    let d = sample.midi - Double(t)
                    return abs(d - 12 * (d / 12).rounded())
                }.min() ?? 12
                if off < 0.75 { hits += 1 }
            }
            return total > 0 ? Double(hits) / Double(total) : 0
        }
        let candidates = stride(from: -0.2, through: 0.8, by: 0.05).map { ($0, matchRate($0)) }
        guard let best = candidates.max(by: { $0.1 < $1.1 }), best.1 - matchRate(musicLag) > 0.02 else { return }
        musicLag = 0.7 * musicLag + 0.3 * best.0
    }

    /// Any part: lead with the voice whose notes have fit the singer best over the last few
    /// seconds, switching only when another is clearly ahead. The other voices are kept at
    /// the leader's position, so the comparison is about which part fits here, and a
    /// switch never moves the position (a drifting voice follower would otherwise win now
    /// and then by fitting somewhere else).
    private func pickLeader() {
        for (part, follower) in followers {
            let delta = follower.logEvidence - (lastEvidence[part] ?? 0)
            lastEvidence[part] = follower.logEvidence
            recentEvidence[part] = 0.995 * (recentEvidence[part] ?? 0) + delta  // about 4 s of memory
        }
        if let best = recentEvidence.max(by: { $0.value < $1.value }),
           best.key != leading, best.value > (recentEvidence[leading] ?? 0) + 8 {
            leading = best.key
        }
        let lead = followers[leading]!
        guard lead.started else { return }
        for (part, follower) in followers where part != leading && abs(follower.position - lead.position) > 0.75 {
            follower.jump(to: lead.position)
        }
    }

    /// Move the shown position along with the tempo and ease it toward the estimate.
    /// A disagreement of more than a beat and a half only wins once it has lasted a while.
    private func glide(dt: Double) {
        let follower = leader
        guard follower.started else { shown = follower.position; return }
        shown += dt * follower.tempo / 60
        let error = follower.position - shown
        if abs(error) < 1.5 {
            shown += error * min(1, dt / 0.3)
            offTrackFor = 0
        } else {
            offTrackFor += dt
            if offTrackFor > 0.8 {
                shown = follower.position
                offTrackFor = 0
            }
        }
    }

    private func decidePart() {
        let ranked = followers.sorted { $0.value.logEvidence > $1.value.logEvidence }
        guard let best = ranked.first, best.value.pitchedFrames >= 50 else { return }
        chosen = best.key
        // Settle once one part is clearly ahead after about five seconds of singing.
        if best.value.pitchedFrames >= 250, ranked.count > 1,
           best.value.logEvidence - ranked[1].value.logEvidence > 15 {
            settle(on: best.key)
        }
    }

    private func settle(on part: Part) {
        if part != chosen, let follower = followers[part] { shown = follower.position }
        chosen = part
        autoDetecting = false
        followers = followers.filter { $0.key == part }
        scorekeepers = scorekeepers.filter { $0.key == part }
        trace.removeAll()
    }

    /// Stop Auto and use this part (also used to switch parts mid-session).
    public func choose(_ part: Part) {
        lock.lock()
        defer { lock.unlock() }
        guard chordPerformance == nil, Part.voices.contains(part) else { return }
        if followers[part] == nil {
            let current = followers[chosen]!
            let performance = Performance(hymn: hymn, part: part, octaveShift: octaveShift)
            let follower = ScoreFollower(performance: performance, tempo: current.tempo, startBeat: current.position)
            follower.anyOctave = true
            follower.diffusion = current.diffusion
            followers[part] = follower
            var keeper = Scorekeeper(tolerance: tolerance)
            keeper.anyOctave = anyOctave
            scorekeepers[part] = keeper
        }
        settle(on: part)
    }

    /// Move to a beat of the performance, e.g. when the singer taps a lyric line.
    public func jump(to beat: Double) {
        lock.withLock {
            for f in followers.values { f.jump(to: beat) }
            shown = beat
            offTrackFor = 0
        }
    }

    private func recordTrace(_ pitch: PitchEstimate?) {
        let follower = leader
        guard isSinging(follower), let pitch else { return }
        let performance = shownPerformance
        let position = shown
        var inTune: Bool?
        var slipped = false
        var drawn = pitch.midi
        if let index = performance.noteIndex(at: position), let _ = performance.notes[index].midi {
            let comparison = PitchComparison(sungMidi: pitch.midi, targets: performance.notes[index].targets,
                                             anyOctave: anyOctave)
            inTune = scorekeepers[chosen]!.isInTune(comparison)
            slipped = coachOctave && comparison.octaves != 0
            if anyOctave { drawn -= Double(12 * comparison.octaves) }
            if recentNote != index { recentCents.removeAll(); recentNote = index }
            recentCents.append(comparison.cents)
            if recentCents.count > 15 { recentCents.removeFirst() }
        }
        trace.append(TracePoint(beat: position, midi: drawn, slipped: slipped, inTune: inTune))
        if trace.count > 4000 { trace.removeFirst(1000) }
    }

    public var live: LiveState {
        lock.lock()
        defer { lock.unlock() }
        let follower = leader
        let performance = shownPerformance
        let position = shown
        let index = performance.noteIndex(at: position)
        let note = index.map { performance.notes[$0] }
        var comparison: PitchComparison?
        if let pitch = lastPitch, let note, !note.isRest {
            comparison = PitchComparison(sungMidi: pitch.midi, targets: note.targets, anyOctave: anyOctave)
        }
        let hint: PitchHint
        if !isSinging(follower) {
            hint = musicBeat != nil ? .intro : .waiting
        } else if note?.isRest ?? true {
            hint = .rest
        } else if let comparison {
            if comparison.octaveOff && !anyOctave {
                hint = .octave
            } else if comparison.octaveOff && coachOctave {
                hint = .octaveSlip
            } else {
                // Average the last few frames so the hint doesn't flicker.
                let recent = recentNote == index && !recentCents.isEmpty ? recentCents : [comparison.cents]
                let mean = recent.reduce(0, +) / Double(recent.count)
                hint = mean > tolerance * 0.5 ? .lower : mean < -tolerance * 0.5 ? .higher : .onPitch
            }
        } else {
            hint = .silent
        }
        let keeper = scorekeepers[chosen]!
        return LiveState(part: chosen, partIsGuess: autoDetecting, started: isSinging(follower), position: position,
                         confidence: follower.confidence, tempo: follower.tempo, sungMidi: lastPitch?.midi,
                         sungMidiNearTarget: lastPitch.map { p in
                             comparison.map { anyOctave ? p.midi - Double(12 * $0.octaves) : p.midi } ?? p.midi
                         },
                         noteIndex: index, comparison: comparison, hint: hint,
                         score: keeper.score(in: performance), streak: keeper.streak,
                         scoredNotes: keeper.scoredNotes)
    }

    public func trace(from: Double, to: Double) -> [TracePoint] {
        lock.withLock { trace.filter { $0.beat >= from && $0.beat <= to } }
    }

    /// Per-note results for the chosen part (note index -> result).
    public var results: [Int: NoteResult] {
        lock.withLock { scorekeepers[chosen]!.results }
    }

    public func summary() -> SessionSummary {
        lock.lock()
        defer { lock.unlock() }
        return SessionSummary(performance: shownPerformance, scorekeeper: scorekeepers[chosen]!,
                              pitchCounts: pitchCounts, musicLag: musicClock == nil ? nil : musicLag)
    }
}

/// What gets shown (and saved) after singing.
public struct SessionSummary: Codable, Sendable, Identifiable {
    public let hymnNumber: Int
    public let title: String
    public let part: String
    public let score: Double
    public let scoredNotes: Int
    public let inTuneNotes: Int
    public let bestStreak: Int
    /// Average offset in cents over all scored notes; positive = tends sharp.
    public let tendencyCents: Double
    public let passes: [PassScore]
    /// The notes that went worst, most off first.
    public let troubleSpots: [TroubleSpot]
    /// When any part counted: share of in-tune singing on each voice, e.g. ["tenor": 0.6].
    public let partShares: [String: Double]?
    // Newer fields are optional so summaries saved by earlier versions still load.
    /// The octave the singer chose to sing in, relative to written (-1: an octave down).
    public let octaveShift: Int?
    /// Share of scored notes sung in each octave, relative to written.
    public let octaves: [OctaveShare]?
    /// Where the singer changed octave between consecutive notes (the first dozen).
    public let octaveChanges: [OctaveChange]?
    /// How many times the singer changed octave.
    public let octaveChangeCount: Int?
    /// Notes missed in more than one verse: the same spot in the music.
    public let recurring: [RecurringSpot]?
    /// Pitched frames per sung semitone, MIDI `pitchCountRange`, for learning the singer's range.
    public let pitchCounts: [Int]?
    /// Practice mode: how far behind the music the singer sang (seconds).
    public let musicLag: Double?

    public static let pitchCountRange = 24...84

    public var id: String { "\(hymnNumber)-\(part)-\(score)-\(scoredNotes)" }

    public struct OctaveShare: Codable, Sendable {
        public let octave: Int
        public let share: Double
    }

    public struct OctaveChange: Codable, Sendable {
        public let kind: String
        public let verse: Int?
        public let lyric: String?
        public let from: Int
        public let to: Int
    }

    public struct RecurringSpot: Codable, Sendable, Identifiable {
        public let kind: String
        public let pitch: String
        /// The word at this spot in each verse where it was missed.
        public let lyrics: [String]
        public let timesMissed: Int
        public let timesSung: Int
        /// Within the octave sung: positive = sharp.
        public let meanCents: Double
        /// Average distance from the note, either way. Much larger than |meanCents| means
        /// the pitch wandered around the note rather than sitting high or low.
        public let meanAbsCents: Double?
        /// Set when most misses were the right note in another octave: that octave,
        /// relative to written (-2: two octaves down).
        public let wrongOctave: Int?
        /// The printed line to practise, in performance beats (its first occurrence).
        public let lineStart: Double
        public let lineEnd: Double
        public let lineText: String

        public var id: String { "\(kind)-\(lineStart)-\(pitch)" }
    }

    public struct PassScore: Codable, Sendable {
        public let kind: String
        public let verse: Int?
        public let score: Double
        public let scoredNotes: Int
    }

    public struct TroubleSpot: Codable, Sendable {
        public let measure: Int
        public let verse: Int?
        public let pitch: String
        public let lyric: String?
        public let accuracy: Double
        public let meanCents: Double
    }

    public init(performance: Performance, scorekeeper: Scorekeeper, pitchCounts: [Int]? = nil, musicLag: Double? = nil) {
        let scored = scorekeeper.results.filter { $0.value.frames >= scorekeeper.minimumFrames }
        hymnNumber = performance.hymn.number
        title = performance.hymn.title
        part = performance.part.rawValue
        score = scorekeeper.score(in: performance)
        scoredNotes = scored.count
        inTuneNotes = scored.values.filter { $0.accuracy >= 0.7 }.count
        bestStreak = scorekeeper.bestStreak
        let frames = scored.values.reduce(0) { $0 + $1.frames }
        tendencyCents = frames > 0 ? scored.values.reduce(0) { $0 + $1.sumCents } / Double(frames) : 0
        let hits = scorekeeper.partHits.values.reduce(0, +)
        partShares = hits > 0 ? scorekeeper.partHits.mapValues { Double($0) / Double(hits) } : nil
        self.pitchCounts = pitchCounts
        self.musicLag = musicLag

        // Octaves, relative to written: which each note was sung in, and where that changed.
        let shift = performance.octaveShift
        octaveShift = performance.part == .anyPart ? nil : shift
        let sungNotes = scored.keys.sorted()
        let noteOctaves = sungNotes.compactMap { i in scorekeeper.octave(ofNote: i).map { (i, $0 + shift) } }
        var shares: [Int: Int] = [:]
        for (_, o) in noteOctaves { shares[o, default: 0] += 1 }
        octaves = noteOctaves.isEmpty ? nil : shares.sorted { $0.key > $1.key }
            .map { OctaveShare(octave: $0.key, share: Double($0.value) / Double(noteOctaves.count)) }
        var changes: [OctaveChange] = []
        var changeCount = 0
        for ((_, a), (i, b)) in zip(noteOctaves, noteOctaves.dropFirst()) where a != b {
            changeCount += 1
            guard changes.count < 12 else { continue }
            let note = performance.notes[i]
            let pass = performance.passes[note.passIndex]
            changes.append(OctaveChange(kind: pass.kind, verse: pass.verse,
                                        lyric: performance.syllableIndex(at: note.start + 1e-6).map { performance.syllables[$0].text },
                                        from: a, to: b))
        }
        octaveChanges = changes
        octaveChangeCount = changeCount

        // The same written note missed in several verses.
        var groups: [String: [Int]] = [:]
        for i in sungNotes where !performance.notes[i].isRest {
            let note = performance.notes[i]
            groups["\(performance.passes[note.passIndex].sectionIndex)@\(note.sourceStart)", default: []].append(i)
        }
        recurring = groups.values.compactMap { indices -> RecurringSpot? in
            let missed = indices.filter { (scored[$0]?.accuracy ?? 1) < 0.5 }
            guard missed.count >= 2, let first = indices.min() else { return nil }
            let note = performance.notes[first]
            let line = performance.lineIndex(at: note.start + 1e-6).map { performance.lines[$0] }
            let lineText = line.map { l in
                performance.syllables[l.syllables].map(\.displayText).joined(separator: " ")
                    .replacingOccurrences(of: "- ", with: "")
            } ?? ""
            let frames = missed.reduce(0) { $0 + (scored[$1]?.frames ?? 0) }
            let cents = missed.reduce(0.0) { $0 + (scored[$1]?.sumCents ?? 0) }
            let absCents = missed.reduce(0.0) { $0 + (scored[$1]?.sumAbsCents ?? 0) }
            // Only a miss in exact-octave mode can be down to the octave.
            let offOctaves = scorekeeper.anyOctave ? [] : missed.compactMap { scorekeeper.octave(ofNote: $0) }.filter { $0 != 0 }
            let wrongOctave = offOctaves.count * 2 >= missed.count
                ? Dictionary(grouping: offOctaves, by: { $0 }).max { $0.value.count < $1.value.count }.map { $0.key + shift }
                : nil
            return RecurringSpot(
                kind: performance.passes[note.passIndex].kind,
                pitch: note.midi.map(NoteName.name) ?? "rest",
                lyrics: missed.compactMap { i in performance.syllableIndex(at: performance.notes[i].start + 1e-6).map { performance.syllables[$0].text } },
                timesMissed: missed.count, timesSung: indices.count,
                meanCents: frames > 0 ? cents / Double(frames) : 0,
                meanAbsCents: frames > 0 ? absCents / Double(frames) : 0, wrongOctave: wrongOctave,
                lineStart: line?.start ?? note.start, lineEnd: line?.end ?? note.end, lineText: lineText)
        }
        // Most often missed first, then furthest off; one entry per word (a syllable
        // sung to two notes would otherwise appear twice).
        .sorted { ($0.timesMissed, $0.meanAbsCents ?? 0) > ($1.timesMissed, $1.meanAbsCents ?? 0) }
        .reduce(into: [RecurringSpot]()) { kept, spot in
            if !kept.contains(where: { $0.lineStart == spot.lineStart && $0.lyrics == spot.lyrics }) { kept.append(spot) }
        }
        .prefix(6).map { $0 }

        passes = performance.passes.compactMap { pass in
            let inPass = scored.filter { performance.notes[$0.key].passIndex == pass.index }
            guard !inPass.isEmpty else { return nil }
            var weighted = 0.0, total = 0.0
            for (i, r) in inPass { weighted += r.accuracy * performance.notes[i].duration; total += performance.notes[i].duration }
            return PassScore(kind: pass.kind, verse: pass.verse, score: 100 * weighted / total, scoredNotes: inPass.count)
        }

        troubleSpots = scored
            .filter { $0.value.accuracy < 0.7 }
            .sorted { ($0.value.accuracy, -$0.value.meanAbsCents) < ($1.value.accuracy, -$1.value.meanAbsCents) }
            .prefix(8)
            .map { index, r in
                let note = performance.notes[index]
                let lyric = performance.syllableIndex(at: note.start + 1e-6).map { performance.syllables[$0].text }
                return TroubleSpot(measure: note.measure, verse: performance.passes[note.passIndex].verse,
                                   pitch: note.midi.map(NoteName.name) ?? "rest", lyric: lyric,
                                   accuracy: r.accuracy, meanCents: r.meanCents)
            }
    }
}

/// Spots the start of a new sung sound: voice returning after a short gap, or the
/// loudness jumping back up after a dip (the consonant between two vowels).
public struct OnsetDetector {
    public init() {}

    private var voicedRun = 0
    private var unvoicedRun = 0
    private var levels: [Double] = []
    private var sinceOnset = 1.0

    public mutating func step(voiced: Bool, level: Double?, dt: Double) -> Bool {
        sinceOnset += dt
        var onset = false
        if voiced {
            if unvoicedRun >= 2 {
                onset = true
            } else if let level, let dip = levels.min(), level - dip > 6 {
                onset = true
            }
            voicedRun += 1
            unvoicedRun = 0
        } else {
            unvoicedRun += 1
            voicedRun = 0
        }
        if let level {
            levels.append(level)
            if levels.count > 6 { levels.removeFirst() }
        }
        if onset && sinceOnset < 0.12 { onset = false }  // one onset per syllable
        if onset { sinceOnset = 0 }
        return onset
    }
}
