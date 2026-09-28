import Foundation
import XCTest
@testable import SingItCore

/// Loads a hymn from the repo's hymns/json (golden output of tools/hymnpdf). Those files are
/// the Church's and aren't in the repository, so tests that need one skip without it.
func loadHymn(_ prefix: String) throws -> Hymn {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../../../hymns/json").standardized
    guard let file = (try? FileManager.default.contentsOfDirectory(atPath: root.path))?.first(where: {
        $0.hasPrefix(prefix) && $0.hasSuffix(".json")
    }) else {
        throw XCTSkip("needs hymns/json/\(prefix)-*.json (hymn files aren't in the repository; see the README)")
    }
    return try Hymn.decode(from: Data(contentsOf: root.appendingPathComponent(file)))
}

/// The made-up test hymn in Fixtures/ (see make_test_hymn.py), always available.
func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)")
}

func loadTestHymn() throws -> Hymn { try Hymn.decode(from: Data(contentsOf: fixtureURL("test-hymn.json"))) }
func loadTestBeatMap() throws -> BeatMap { try BeatMap.decode(from: Data(contentsOf: fixtureURL("test-hymn.beatmap.json"))) }

/// A simulated singer: pitch frames for a performance at a given tempo, with vibrato,
/// short breaths between notes, an optional constant detune and optional wrong notes.
/// Each frame carries the score beat the singer is really at.
func singFrames(_ performance: Performance, bpm: Double, detuneCents: Double = 0, from: Double = 0,
                to: Double? = nil, wrongEvery: Int = 0, dt: Double = 0.02) -> [(pitch: PitchEstimate?, dt: Double, beat: Double)] {
    var frames: [(pitch: PitchEstimate?, dt: Double, beat: Double)] = []
    let beatsPerFrame = dt * bpm / 60
    var beat = from
    let end = min(to ?? performance.totalBeats, performance.totalBeats)
    while beat < end {
        let t = (beat - from) / beatsPerFrame * dt
        let index = performance.noteIndex(at: beat)!
        let note = performance.notes[index]
        let breath = note.end - beat < 2 * beatsPerFrame  // a short breath at the end of each note
        if var midi = note.midi.map(Double.init), !breath {
            if wrongEvery > 0 && index % wrongEvery == 0 { midi += 3 }
            midi += detuneCents / 100 + 0.3 * sin(2 * .pi * 5.5 * t)
            frames.append((PitchEstimate(midi: midi, clarity: 0.9), dt, beat))
        } else {
            frames.append((nil, dt, beat))
        }
        beat += beatsPerFrame
    }
    return frames
}

final class HymnDataTests: XCTestCase {
    func testEveryGoldenHymnDecodes() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../../hymns/json").standardized
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0.hasSuffix(".json") }
        guard !files.isEmpty else { throw XCTSkip("no hymns in hymns/json (see the README)") }
        for file in files {
            let hymn = try Hymn.decode(from: Data(contentsOf: root.appendingPathComponent(file)))
            for part in Part.allCases {
                let p = Performance(hymn: hymn, part: part)
                XCTAssertFalse(p.notes.isEmpty, "\(file) \(part)")
                // Contiguous: every beat of the performance has exactly one note or rest.
                for (a, b) in zip(p.notes, p.notes.dropFirst()) {
                    XCTAssertEqual(a.end, b.start, accuracy: 1e-6, "\(file) \(part) at \(a.start)")
                }
                XCTAssertEqual(p.notes.last!.end, p.totalBeats, accuracy: 1e-6, "\(file) \(part)")
            }
        }
    }

    func testSpiritOfGodPerformanceOrder() throws {
        let hymn = try loadHymn("0002")
        let p = Performance(hymn: hymn, part: .bass)
        XCTAssertEqual(p.passes.map(\.verse), [1, nil, 2, nil, 3, nil, 4, nil])
        XCTAssertEqual(p.totalBeats, 4 * 128)
        XCTAssertEqual(p.start(ofVerse: 2), 128)
        // Verse 2 starts "The Lord is ex-tend-ing"
        let v2 = p.syllables.filter { $0.passIndex == 2 }.prefix(3).map(\.text)
        XCTAssertEqual(v2, ["The", "Lord", "is"])
        XCTAssertEqual(NoteName.name(p.notes[0].midi!), "B♭2")
        XCTAssertEqual(hymn.quarterBPMRange, 96...112)
    }

    func testDottedTempoCountsDottedQuarters() throws {
        let hymn = try loadHymn("0105")  // 6/8, dotted quarter = 52-66
        XCTAssertEqual(hymn.quarterBPMRange.lowerBound, 78, accuracy: 1e-9)
    }

    func testMensEchoReplacesMainLineForTenorAndBass() throws {
        let hymn = try loadHymn("0105")
        let echo = try XCTUnwrap(hymn.sections[1].lyrics.first { $0.parts != nil })
        let tenor = Performance(hymn: hymn, part: .tenor), soprano = Performance(hymn: hymn, part: .soprano)
        let chorusStart = tenor.passes[1].start - hymn.sections[1].start
        let window = (echo.start! + chorusStart)..<(echo.end! + chorusStart)
        let tenorWords = tenor.syllables.filter { window.contains($0.start) }.map(\.text)
        let sopranoWords = soprano.syllables.filter { window.contains($0.start) }.map(\.text)
        XCTAssertEqual(tenorWords, echo.syllables.map(\.text))
        XCTAssertNotEqual(tenorWords, sopranoWords)
    }

    func testOptionalNoteOnlyInItsVerse() throws {
        let hymn = try loadHymn("0085")
        let optional = try XCTUnwrap(hymn.notes(for: .soprano).first { $0.verses != nil })
        let p = Performance(hymn: hymn, part: .soprano)
        for pass in p.passes {
            let note = try XCTUnwrap(p.notes.first { $0.passIndex == pass.index && $0.sourceStart == optional.start })
            XCTAssertEqual(note.isRest, !(optional.verses!.contains(pass.verse!)), "verse \(pass.verse!)")
        }
    }

    func testLyricLinesFollowPrintedSystems() throws {
        let p = Performance(hymn: try loadHymn("0002"), part: .soprano)
        let first = p.lines[0]
        let text = p.syllables[first.syllables].map(\.displayText).joined(separator: " ")
        XCTAssertEqual(text, "The Spir- it of God like a fire is burn- ing!")
    }
}

final class PitchDetectorTests: XCTestCase {
    let sr = 16_000.0

    func tone(_ f: Double, harmonics: [Double] = [1], seconds: Double = 0.064, noise: Float = 0) -> [Float] {
        (0..<Int(sr * seconds)).map { i in
            let t = Double(i) / sr
            var x = 0.0
            for (k, a) in harmonics.enumerated() { x += a * sin(2 * .pi * f * Double(k + 1) * t) }
            return Float(0.2 * x) + noise * Float.random(in: -1...1)
        }
    }

    func testSine() throws {
        let d = PitchDetector(sampleRate: sr)
        let p = try XCTUnwrap(d.estimate(tone(220)))
        XCTAssertEqual(p.midi, 57, accuracy: 0.1)
    }

    func testVoiceLikeToneAcrossTheRange() throws {
        let d = PitchDetector(sampleRate: sr)
        // Rich harmonics with a weak fundamental, as in a bass voice.
        for midi in [40.0, 45, 52, 60, 67, 74, 79] {
            let f = 440 * pow(2, (midi - 69) / 12)
            let p = try XCTUnwrap(d.estimate(tone(f, harmonics: [0.4, 1, 0.8, 0.5, 0.3], noise: 0.02)), "\(midi)")
            XCTAssertEqual(p.midi, midi, accuracy: 0.15, "\(midi)")
            XCTAssertGreaterThan(p.clarity, 0.7)
        }
    }

    func testSilenceAndNoise() {
        let d = PitchDetector(sampleRate: sr)
        XCTAssertNil(d.estimate([Float](repeating: 0, count: 1024)))
        XCTAssertNil(d.estimate((0..<1024).map { _ in Float.random(in: -0.3...0.3) }))
    }
}

final class ScoreFollowerTests: XCTestCase {
    /// Largest gap between where the follower thinks the singer is and where they are.
    func trackingErrors(_ p: Performance, bpm: Double, detune: Double = 0, wrongEvery: Int = 0,
                        skipFirst: Double = 4) -> [Double] {
        let follower = ScoreFollower(performance: p)
        var errors: [Double] = []
        for frame in singFrames(p, bpm: bpm, detuneCents: detune, wrongEvery: wrongEvery) {
            follower.update(dt: frame.dt, pitch: frame.pitch)
            if frame.beat > skipFirst { errors.append(abs(follower.position - frame.beat)) }
        }
        return errors
    }

    func testFollowsWholeHymnAtAssumedTempo() throws {
        let p = Performance(hymn: try loadHymn("0002"), part: .soprano)
        let errors = trackingErrors(p, bpm: 104)
        XCTAssertLessThan(errors.max()!, 1.0)
        XCTAssertLessThan(errors.reduce(0, +) / Double(errors.count), 0.3)
    }

    func testFollowsSlowerAndFasterCongregations() throws {
        for (prefix, part) in [("0002", Part.bass), ("0301", .alto), ("0204", .tenor)] {
            let p = Performance(hymn: try loadHymn(prefix), part: part)
            let mid = (p.hymn.quarterBPMRange.lowerBound + p.hymn.quarterBPMRange.upperBound) / 2
            for bpm in [mid * 0.85, mid * 1.15] {
                let errors = trackingErrors(p, bpm: bpm, skipFirst: 8)
                let late = errors.suffix(errors.count / 2)
                XCTAssertLessThan(late.reduce(0, +) / Double(late.count), 0.5, "\(prefix) \(part) at \(bpm)")
            }
        }
    }

    func testFollowsAnOffKeySingerWithWrongNotes() throws {
        let p = Performance(hymn: try loadHymn("0006"), part: .soprano)
        let errors = trackingErrors(p, bpm: 92, detune: 70, wrongEvery: 7)
        XCTAssertLessThan(errors.reduce(0, +) / Double(errors.count), 0.5)
    }

    func testWaitsForTheSingerDuringTheIntroduction() throws {
        let p = Performance(hymn: try loadHymn("0002"), part: .soprano)
        let follower = ScoreFollower(performance: p)
        for _ in 0..<500 { follower.update(dt: 0.02, pitch: nil) }  // 10 s of organ intro, no voice
        XCTAssertFalse(follower.started)
        XCTAssertEqual(follower.position, 0, accuracy: 0.1)
    }
}

final class SessionTests: XCTestCase {
    func run(_ session: SingingSession, _ frames: [(pitch: PitchEstimate?, dt: Double, beat: Double)]) {
        for frame in frames { session.process(pitch: frame.pitch, dt: frame.dt) }
    }

    func testAutoDetectsTheBassPart() throws {
        let hymn = try loadHymn("0002")
        let session = SingingSession(hymn: hymn, part: nil)
        run(session, singFrames(Performance(hymn: hymn, part: .bass), bpm: 100, to: 32))
        XCTAssertEqual(session.live.part, .bass)
        XCTAssertFalse(session.live.partIsGuess)
    }

    func testAutoDetectsAlto() throws {
        let hymn = try loadHymn("0301")
        let session = SingingSession(hymn: hymn, part: nil)
        run(session, singFrames(Performance(hymn: hymn, part: .alto), bpm: 88, to: 32))
        XCTAssertEqual(session.live.part, .alto)
    }

    func testInTuneSingingScoresHighAndFlatSingingLow() throws {
        let hymn = try loadHymn("0006")
        let p = Performance(hymn: hymn, part: .tenor)
        let good = SingingSession(hymn: hymn, part: .tenor)
        run(good, singFrames(p, bpm: 92, to: 56))
        XCTAssertGreaterThan(good.live.score, 85)

        let flat = SingingSession(hymn: hymn, part: .tenor)
        let frames = singFrames(p, bpm: 92, detuneCents: -80, to: 56)
        run(flat, frames)
        XCTAssertLessThan(flat.live.score, 30)
        // Mid-note, the hint says to sing higher.
        let partway = SingingSession(hymn: hymn, part: .tenor)
        run(partway, Array(frames.prefix(300)))
        let hint = partway.live.hint
        XCTAssertTrue(hint == .higher || hint == .rest || hint == .silent, "\(hint)")
        let summary = flat.summary()
        XCTAssertLessThan(summary.tendencyCents, -50)
        XCTAssertFalse(summary.troubleSpots.isEmpty)
    }

    func testAudioPipelineEndToEnd() throws {
        // Synthesised voice-like audio through framing + YIN + follower + scoring.
        let hymn = try loadHymn("0301")
        let p = Performance(hymn: hymn, part: .soprano)
        let sr = 16_000.0, bpm = 88.0
        var samples: [Float] = []
        var phase = 0.0
        for note in p.notes where note.start < 16 {
            let n = Int(note.duration * 60 / bpm * sr)
            for i in 0..<n {
                guard let midi = note.midi, i < n - Int(0.04 * sr) else { samples.append(0); continue }
                let f = 440 * pow(2, (Double(midi) - 69) / 12)
                phase += 2 * .pi * f / sr
                samples.append(Float(0.15 * sin(phase) + 0.08 * sin(2 * phase) + 0.04 * sin(3 * phase)))
            }
        }
        let session = SingingSession(hymn: hymn, part: .soprano, sampleRate: sr)
        stride(from: 0, to: samples.count, by: 1024).forEach {
            session.process(Array(samples[$0..<min($0 + 1024, samples.count)]))
        }
        let live = session.live
        XCTAssertEqual(live.position, 16, accuracy: 1.0)
        XCTAssertGreaterThan(live.score, 90)
    }
}

final class UntrainedSingerTests: XCTestCase {
    /// Mean |shown position - true position| over a whole performance, after the first bar.
    func meanError(_ prefix: String, _ part: Part, bpm: Double, jitter: Double, steady: Bool, seed: UInt64) throws -> Double {
        let hymn = try loadHymn(prefix)
        let session = SingingSession(hymn: hymn, part: part, steadyTempo: steady)
        var errs: [Double] = []
        for f in SloppySinger(bpm: bpm, tempoJitter: jitter, seed: seed).frames(Performance(hymn: hymn, part: part)) {
            session.process(pitch: f.pitch, dt: f.dt, level: f.level)
            if f.beat > 4 { errs.append(abs(session.live.position - f.beat)) }
        }
        return errs.reduce(0, +) / Double(errs.count)
    }

    func testFollowsAnOffKeySingerAnOctaveDownWithTheOrgan() throws {
        for (prefix, part, bpm, seed) in [("0002", Part.tenor, 85.0, 11 as UInt64), ("0301", .tenor, 75, 41), ("0098", .bass, 85, 81)] {
            let error = try meanError(prefix, part, bpm: bpm, jitter: 0.08, steady: true, seed: seed)
            XCTAssertLessThan(error, 0.6, "\(prefix) \(part)")
        }
    }

    func testAnyPartFollowsAnUntrainedSingerOnTheTenorLine() throws {
        let hymn = try loadHymn("0002")
        for (mode, jitter, steady, limit) in [(Part.tenor, 0.25, false, 1.2), (.anyPart, 0.25, false, 1.2),
                                              (.tenor, 0.08, true, 0.6), (.anyPart, 0.08, true, 0.6)] {
            let session = SingingSession(hymn: hymn, part: mode, steadyTempo: steady)
            var errs: [Double] = []
            for f in SloppySinger(bpm: 104, tempoJitter: jitter, seed: 5).frames(Performance(hymn: hymn, part: .tenor)) {
                session.process(pitch: f.pitch, dt: f.dt, level: f.level)
                if f.beat > 4 { errs.append(abs(session.live.position - f.beat)) }
            }
            let mean = errs.reduce(0, +) / Double(errs.count)
            print(String(format: "%@ jitter %.2f: mean error %.2f beats", mode.rawValue, jitter, mean))
            XCTAssertLessThan(mean, limit, "\(mode) jitter \(jitter)")
        }
    }

    func testFollowsAnUnevenSingerPractisingAlone() throws {
        for (prefix, part, bpm, seed) in [("0002", Part.tenor, 85.0, 10 as UInt64), ("0006", .bass, 80, 30), ("0030", .tenor, 95, 70)] {
            let error = try meanError(prefix, part, bpm: bpm, jitter: 0.25, steady: false, seed: seed)
            XCTAssertLessThan(error, 1.2, "\(prefix) \(part)")
        }
    }
}

final class MelodyAndAnyPartTests: XCTestCase {
    func testMelodyIsTheSopranoLine() throws {
        let hymn = try loadHymn("0002")
        let melody = Performance(hymn: hymn, part: .melody), soprano = Performance(hymn: hymn, part: .soprano)
        XCTAssertEqual(melody.notes, soprano.notes)
        XCTAssertEqual(Part.melody.displayName, "Melody")
    }

    func testAnyPartAcceptsEveryChordNote() throws {
        let p = Performance(hymn: try loadHymn("0002"), part: .anyPart)
        // First chord of The Spirit of God: F4 D4 over B♭3 B♭2, melody first.
        XCTAssertEqual(p.notes[0].targets, [65, 62, 58, 46])
        XCTAssertEqual(p.notes[0].targetParts, ["soprano", "alto", "tenor", "bass"])
        XCTAssertEqual(p.syllables.first?.text, "The")
    }

    func testAnyPartScoresWhicheverPartIsSung() throws {
        let hymn = try loadHymn("0002")
        for voice in [Part.tenor, .soprano] {
            let session = SingingSession(hymn: hymn, part: .anyPart)
            for f in singFrames(Performance(hymn: hymn, part: voice), bpm: 104, to: 32) {
                session.process(pitch: f.pitch, dt: f.dt)
            }
            XCTAssertGreaterThan(session.live.score, 80, "\(voice)")
            let shares = try XCTUnwrap(session.summary().partShares)
            XCTAssertEqual(shares.max { $0.value < $1.value }?.key, voice.rawValue)
        }
    }

    func testAnyPartKeepsPlaceWhenTheSingerSwitchesParts() throws {
        let hymn = try loadHymn("0002")
        let session = SingingSession(hymn: hymn, part: .anyPart)
        let tenor = singFrames(Performance(hymn: hymn, part: .tenor), bpm: 104, to: 32)
        let melody = singFrames(Performance(hymn: hymn, part: .soprano), bpm: 104, from: 32, to: 64)
        var errs: [Double] = []
        for f in tenor + melody {
            session.process(pitch: f.pitch, dt: f.dt)
            if f.beat > 4 { errs.append(abs(session.live.position - f.beat)) }
        }
        // Handing over to the new part takes a few seconds, with a brief lag around the switch.
        XCTAssertLessThan(errs.reduce(0, +) / Double(errs.count), 0.4)
        XCTAssertLessThan(errs.max()!, 2)
        XCTAssertGreaterThan(session.live.score, 80)
        let shares = try XCTUnwrap(session.summary().partShares)
        XCTAssertGreaterThan(shares["tenor"] ?? 0, 0.3)
        XCTAssertGreaterThan(shares["soprano"] ?? 0, 0.3)
    }

    func testAnyPartStillMarksNotesOutsideTheChord() throws {
        let hymn = try loadHymn("0002")
        let session = SingingSession(hymn: hymn, part: .anyPart)
        // The melody a tritone off lands on no chord note.
        for f in singFrames(Performance(hymn: hymn, part: .soprano), bpm: 104, detuneCents: 600, to: 32) {
            session.process(pitch: f.pitch, dt: f.dt)
        }
        XCTAssertLessThan(session.live.score, 40)
    }

    func testOctaveFreeComparisonPicksTheNearestNoteName() {
        // Sung B♭2 against a chord of F4, D4, B♭3: B♭3 by name, an octave down.
        let c = PitchComparison(sungMidi: 46.2, targets: [65, 62, 58], anyOctave: true)
        XCTAssertEqual(c.target, 58)
        XCTAssertEqual(c.octaves, -1)
        XCTAssertEqual(c.cents, 20, accuracy: 1e-6)
    }
}

final class PracticeModeTests: XCTestCase {
    func loadBeatMap(_ prefix: String) throws -> BeatMap {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../../hymns/beatmaps").standardized
        guard let file = (try? FileManager.default.contentsOfDirectory(atPath: root.path))?.first(where: {
            $0.hasPrefix(prefix) && $0.hasSuffix(".json")
        }) else { throw XCTSkip("needs hymns/beatmaps/\(prefix)-*.json (see the README)") }
        return try BeatMap.decode(from: Data(contentsOf: root.appendingPathComponent(file)))
    }

    func testBeatMapConvertsBothWays() throws {
        let map = try loadBeatMap("0002")
        XCTAssertLessThan(map.beat(atTime: 5), 0)  // the introduction
        XCTAssertEqual(map.beat(atTime: map.singingStart), 0, accuracy: 0.2)
        for beat in [0.0, 17.5, 128, 300, 511] {
            XCTAssertEqual(map.beat(atTime: map.time(atBeat: beat)), beat, accuracy: 0.01)
        }
        XCTAssertEqual(map.url.pathExtension, "mp3")
    }

    func testEveryHymnHasABeatMapCoveringItsPerformance() throws {
        for prefix in ["0002", "0006", "0019", "0026", "0027", "0030", "0060", "0085", "0098", "0105",
                       "0116", "0136", "0152", "0193", "0204", "0227", "0239", "0301"] {
            let map = try loadBeatMap(prefix)
            let performance = Performance(hymn: try loadHymn(prefix), part: .soprano)
            XCTAssertEqual(map.beats.last![1], performance.totalBeats - 0.125, accuracy: 1e-6, prefix)
        }
    }

    /// Singing along with the music: the position is the music's, even through a stretch
    /// where the singer is badly off.
    func testPositionComesFromTheMusic() throws {
        let hymn = try loadHymn("0002")
        let session = SingingSession(hymn: hymn, part: .melody)
        let sr = 16_000.0, bpm = 95.0
        // Two seconds of introduction (silence from the singer), then the melody.
        var samples = [Float](repeating: 0, count: Int(2 * sr))
        var phase = 0.0
        for note in Performance(hymn: hymn, part: .melody).notes where note.start < 16 {
            let n = Int(note.duration * 60 / bpm * sr)
            for i in 0..<n {
                guard let midi = note.midi, i < n - Int(0.04 * sr) else { samples.append(0); continue }
                phase += 2 * .pi * 440 * pow(2, (Double(midi) - 12 - 69) / 12) / sr  // an octave down
                samples.append(Float(0.15 * sin(phase) + 0.08 * sin(2 * phase)))
            }
        }
        let rate = bpm / 60
        var beatAtNext = -2 * rate
        for start in stride(from: 0, to: samples.count, by: 1024) {
            let block = Array(samples[start..<min(start + 1024, samples.count)])
            session.setMusicClock(beat: beatAtNext, rate: rate)
            session.process(block)
            beatAtNext += Double(block.count) / sr * rate
            if beatAtNext < -0.5 { XCTAssertEqual(session.live.hint, .intro) }
        }
        XCTAssertEqual(session.live.position, beatAtNext, accuracy: 0.1)
        XCTAssertGreaterThan(session.live.score, 90)
    }
}

final class OctaveAndVoiceTests: XCTestCase {
    func testOctaveShiftMovesEveryNote() throws {
        let hymn = try loadHymn("0002")
        let written = Performance(hymn: hymn, part: .melody), down = Performance(hymn: hymn, part: .melody, octaveShift: -1)
        XCTAssertEqual(zip(written.notes, down.notes).filter { $0.midi.map { $0 - 12 } != $1.midi }.count, 0)
        XCTAssertEqual(down.octaveShift, -1)
    }

    /// Frames for the melody sung an octave down, dropping to two octaves down for `lowFrom..<lowTo` beats.
    func melodyFrames(_ hymn: Hymn, to: Double, lowFrom: Double = .infinity, lowTo: Double = .infinity)
        -> [(pitch: PitchEstimate?, dt: Double, beat: Double)] {
        singFrames(Performance(hymn: hymn, part: .melody, octaveShift: -1), bpm: 104, to: to).map { f in
            guard let p = f.pitch, f.beat >= lowFrom, f.beat < lowTo else { return f }
            return (PitchEstimate(midi: p.midi - 12, clarity: p.clarity), f.dt, f.beat)
        }
    }

    func testExactOctaveCountsOctaveDropsAsMisses() throws {
        let hymn = try loadHymn("0002")
        let steady = SingingSession(hymn: hymn, part: .melody, anyOctave: false, octaveShift: -1)
        for f in melodyFrames(hymn, to: 64) { steady.process(pitch: f.pitch, dt: f.dt) }
        XCTAssertGreaterThan(steady.live.score, 85)

        let wandering = SingingSession(hymn: hymn, part: .melody, anyOctave: false, octaveShift: -1)
        for f in melodyFrames(hymn, to: 64, lowFrom: 16, lowTo: 40) { wandering.process(pitch: f.pitch, dt: f.dt) }
        XCTAssertLessThan(wandering.live.score, 75)
        let summary = wandering.summary()
        XCTAssertEqual(summary.octaveShift, -1)
        XCTAssertEqual(summary.octaveChangeCount, 2)  // down at beat 16, back up at 40
        let shares = Dictionary(uniqueKeysWithValues: (summary.octaves ?? []).map { ($0.octave, $0.share) })
        XCTAssertGreaterThan(shares[-2] ?? 0, 0.25)
        XCTAssertGreaterThan(shares[-1] ?? 0, 0.5)
        XCTAssertEqual(summary.octaveChanges?.first?.from, -1)
        XCTAssertEqual(summary.octaveChanges?.first?.to, -2)

        // With any octave, the same singing scores well but the octave report is the same.
        let relaxed = SingingSession(hymn: hymn, part: .melody, anyOctave: true)
        for f in melodyFrames(hymn, to: 64, lowFrom: 16, lowTo: 40) { relaxed.process(pitch: f.pitch, dt: f.dt) }
        XCTAssertGreaterThan(relaxed.live.score, 85)
        XCTAssertEqual(relaxed.summary().octaveChangeCount, 2)
    }

    func testChosenOctaveCoachesSlipsWithoutCountingThemAsMisses() throws {
        let hymn = try loadHymn("0002")
        let coached = SingingSession(hymn: hymn, part: .melody, anyOctave: true, octaveShift: -1, coachOctave: true)
        var slipHints = 0
        for f in melodyFrames(hymn, to: 64, lowFrom: 16, lowTo: 40) {
            coached.process(pitch: f.pitch, dt: f.dt)
            if coached.live.hint == .octaveSlip { slipHints += 1 }
        }
        XCTAssertGreaterThan(coached.live.score, 85)       // the two-octaves-down stretch still counts
        XCTAssertGreaterThan(slipHints, 100)                // but it was pointed out
        XCTAssertEqual(coached.summary().octaveChangeCount, 2)
    }

    func testVoiceRangeFromPitchCounts() {
        var counts = [Int](repeating: 0, count: SessionSummary.pitchCountRange.count)
        for midi in 46...62 { counts[midi - SessionSummary.pitchCountRange.lowerBound] = 200 }
        counts[80 - SessionSummary.pitchCountRange.lowerBound] = 10  // a stray squeak
        let range = try? XCTUnwrap(VoiceRange.from(pitchCounts: counts))
        XCTAssertEqual(range?.low ?? 0, 47, accuracy: 1)
        XCTAssertEqual(range?.high ?? 0, 61, accuracy: 1)
        XCTAssertNil(VoiceRange.from(pitchCounts: [Int](repeating: 1, count: 61)))
    }

    func testVoiceFitForAMaleVoiceOnTheSpiritOfGod() throws {
        // The user's measured range, B♭2–D4.
        let options = VoiceFit.options(for: try loadHymn("0002"), range: VoiceRange(low: 46, high: 62))
        let best = try XCTUnwrap(options.first)
        XCTAssertGreaterThan(best.inRange, 0.95, best.label)
        let melodyDown = try XCTUnwrap(options.first { $0.part == .melody && $0.octaveShift == -1 })
        XCTAssertGreaterThan(melodyDown.notesTooHigh, 0)  // E♭4 at the top
        XCTAssertEqual(melodyDown.notesTooLow, 0)
        for option in options.prefix(4) {
            print("\(option.label): \(Int((option.inRange * 100).rounded()))% in range "
                  + "(\(NoteName.name(option.lowest))–\(NoteName.name(option.highest))), "
                  + "\(option.notesTooHigh) too high, \(option.notesTooLow) too low")
        }
    }
}

final class PracticeCoachingTests: XCTestCase {
    /// Practice mode with a singer who sings `lag` seconds behind the music.
    func practise(_ hymn: Hymn, lag: Double, to: Double, wrong: ((PerformedNote) -> Bool)? = nil) -> SingingSession {
        let session = SingingSession(hymn: hymn, part: .melody)
        let performance = Performance(hymn: hymn, part: .melody)
        let rate = 95.0 / 60
        for f in singFrames(performance, bpm: 95, to: to) {
            var pitch = f.pitch
            if let p = pitch, let wrong, let i = performance.noteIndex(at: f.beat), wrong(performance.notes[i]) {
                pitch = PitchEstimate(midi: p.midi + 4, clarity: p.clarity)
            }
            // The music is `lag` seconds ahead of what the singer is singing.
            let heardBeat = f.beat + lag * rate
            session.setMusicClock(beat: heardBeat, rate: rate)
            session.process(pitch: pitch, dt: f.dt, knownBeat: heardBeat)
        }
        return session
    }

    func testMeasuresHowFarBehindTheMusicTheSingerIs() throws {
        let hymn = try loadHymn("0002")
        let session = practise(hymn, lag: 0.3, to: 64)
        XCTAssertEqual(session.musicLag, 0.3, accuracy: 0.1)
        XCTAssertGreaterThan(session.live.score, 85)
        XCTAssertEqual(session.summary().musicLag ?? 0, 0.3, accuracy: 0.1)
    }

    func testReportsTheSameMistakeInEveryVerseOnce() throws {
        let hymn = try loadHymn("0002")
        // Miss the first note of "The lat-ter-day" line (written beat 17) in every verse.
        let session = practise(hymn, lag: 0, to: 512) { $0.sourceStart == 17 }
        let spots = try XCTUnwrap(session.summary().recurring)
        let spot = try XCTUnwrap(spots.first)
        XCTAssertEqual(spot.timesMissed, 4)
        XCTAssertEqual(spot.lyrics.count, 4)
        XCTAssertEqual(spot.meanCents, 400, accuracy: 60)
        XCTAssertLessThanOrEqual(spot.lineStart, 17)
        XCTAssertGreaterThan(spot.lineEnd, 17)
        XCTAssertTrue(spot.lineText.contains("lat"), spot.lineText)
    }
}

final class PartSynthTests: XCTestCase {
    func testRendersThePartOnTheRecordingsTimeline() throws {
        let bass = Performance(hymn: try loadHymn("0002"), part: .bass)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../../hymns/beatmaps/0002-the-spirit-of-god.json").standardized
        let map = try BeatMap.decode(from: Data(contentsOf: root))
        let sr = 16_000.0
        let audio = PartSynth.render(bass, beatMap: map, sampleRate: sr)
        XCTAssertEqual(Double(audio.count) / sr, map.duration, accuracy: 0.01)
        // Silent during the organ introduction.
        XCTAssertEqual(audio[0..<Int((map.singingStart - 0.5) * sr)].map(abs).max() ?? 1, 0)
        // Each of the first few bass notes sounds at its pitch, when the recording plays it.
        let detector = PitchDetector(sampleRate: sr)
        for note in bass.notes.prefix(6) where note.duration >= 1 {
            let middle = map.time(atBeat: note.start + note.duration / 2)
            let frame = Array(audio[Int(middle * sr)..<Int(middle * sr) + 1024])
            let heard = try XCTUnwrap(detector.estimate(frame), "beat \(note.start)")
            XCTAssertEqual(heard.midi, Double(note.midi!), accuracy: 0.2, "beat \(note.start)")
        }
    }
}


/// The app's core behaviour on the made-up test hymn, so it's tested without any of the
/// Church's files. (The tests above cover the same ground on real hymns when present.)
final class TestHymnTests: XCTestCase {
    func testDecodesAndLaysOutEveryPart() throws {
        let hymn = try loadTestHymn()
        for part in Part.allCases {
            let p = Performance(hymn: hymn, part: part)
            XCTAssertEqual(p.totalBeats, 144, "\(part)")
            for (a, b) in zip(p.notes, p.notes.dropFirst()) { XCTAssertEqual(a.end, b.start, accuracy: 1e-9) }
        }
        let p = Performance(hymn: hymn, part: .melody)
        XCTAssertEqual(p.passes.map(\.verse), [1, 2])
        XCTAssertEqual(p.lines.count, 6)  // three printed systems, two passes
        XCTAssertEqual(p.syllables[p.lines[3].syllables].first?.text, "Yea,")
        XCTAssertEqual(Performance(hymn: hymn, part: .anyPart).notes[0].targets, [67, 62, 59, 55])
    }

    func testFollowsAnUntrainedSinger() throws {
        let hymn = try loadTestHymn()
        // Singing alone with uneven timing is looser: the test hymn's phrases end on five-beat
        // notes, and a singer who stretches notes by up to 25% runs over a beat long there.
        for (part, jitter, steady, limit) in [(Part.tenor, 0.08, true, 0.6), (.melody, 0.25, false, 1.5)] {
            let session = SingingSession(hymn: hymn, part: part, steadyTempo: steady)
            var errs: [Double] = []
            for f in SloppySinger(bpm: 90, tempoJitter: jitter, seed: 3).frames(Performance(hymn: hymn, part: part)) {
                session.process(pitch: f.pitch, dt: f.dt, level: f.level)
                if f.beat > 4 { errs.append(abs(session.live.position - f.beat)) }
            }
            XCTAssertLessThan(errs.reduce(0, +) / Double(errs.count), limit, "\(part)")
        }
    }

    func testScoresInTuneHighAndFlatLow() throws {
        let hymn = try loadTestHymn()
        let p = Performance(hymn: hymn, part: .alto)
        let good = SingingSession(hymn: hymn, part: .alto)
        for f in singFrames(p, bpm: 90) { good.process(pitch: f.pitch, dt: f.dt) }
        XCTAssertGreaterThan(good.live.score, 85)
        let flat = SingingSession(hymn: hymn, part: .alto)
        for f in singFrames(p, bpm: 90, detuneCents: -80) { flat.process(pitch: f.pitch, dt: f.dt) }
        XCTAssertLessThan(flat.live.score, 30)
    }

    func testAutoAndAnyPart() throws {
        let hymn = try loadTestHymn()
        let auto = SingingSession(hymn: hymn, part: nil)
        for f in singFrames(Performance(hymn: hymn, part: .bass), bpm: 90) { auto.process(pitch: f.pitch, dt: f.dt) }
        XCTAssertEqual(auto.live.part, .bass)
        let any = SingingSession(hymn: hymn, part: .anyPart)
        for f in singFrames(Performance(hymn: hymn, part: .tenor), bpm: 90) { any.process(pitch: f.pitch, dt: f.dt) }
        XCTAssertGreaterThan(any.live.score, 80)
    }

    func testOctaveCoaching() throws {
        let hymn = try loadTestHymn()
        let session = SingingSession(hymn: hymn, part: .melody, octaveShift: -1, coachOctave: true)
        var slips = 0
        for f in singFrames(Performance(hymn: hymn, part: .melody, octaveShift: -1), bpm: 90) {
            let inVerse = f.beat.truncatingRemainder(dividingBy: 72)
            let low = inVerse >= 24 && inVerse < 40  // the third phrase of each verse two octaves down
            let pitch = f.pitch.map { low ? PitchEstimate(midi: $0.midi - 12, clarity: $0.clarity) : $0 }
            session.process(pitch: pitch, dt: f.dt)
            if session.live.hint == .octaveSlip { slips += 1 }
        }
        XCTAssertGreaterThan(session.live.score, 85)
        XCTAssertGreaterThan(slips, 50)
        XCTAssertEqual(session.summary().octaveChangeCount, 4)  // down and up, in each verse
    }

    func testPracticeModeAndPartPlayback() throws {
        let hymn = try loadTestHymn(), map = try loadTestBeatMap()
        XCTAssertEqual(map.beat(atTime: map.singingStart), 0, accuracy: 0.01)
        let tenor = Performance(hymn: hymn, part: .tenor)
        let audio = PartSynth.render(tenor, beatMap: map, sampleRate: 16_000)
        let middle = map.time(atBeat: 0.5)
        let heard = try XCTUnwrap(PitchDetector(sampleRate: 16_000).estimate(Array(audio[Int(middle * 16_000)..<Int(middle * 16_000) + 1024])))
        XCTAssertEqual(heard.midi, Double(tenor.notes[0].midi!), accuracy: 0.2)

        let session = SingingSession(hymn: hymn, part: .tenor)
        let rate = 1.5
        for f in singFrames(tenor, bpm: 90) {
            session.setMusicClock(beat: f.beat, rate: rate)
            session.process(pitch: f.pitch, dt: f.dt, knownBeat: f.beat)
        }
        XCTAssertGreaterThan(session.live.score, 85)
    }
}
