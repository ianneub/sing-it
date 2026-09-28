import Foundation
import SingItCore

// Replays a recording through pitch detection and the score follower, printing what was
// heard and where the follower thought the singer was.
//
//   singit-replay AUDIO.f32 HYMN.json PART [VERSE] [--every SECONDS] [--alone] [--onsets] [--csv]
//                 [--beatmap MAP.json] [--octave N] [--exact]
// --beatmap replays a practice session: the recording started with the music, so its
// clock gives the music's position. --octave N sings the part N octaves from written;
// --exact holds the singer to it (otherwise any octave counts).
//
// AUDIO.f32 is raw 32-bit float, mono, 16 kHz:
//   ffmpeg -i rec.m4a -ac 1 -ar 16000 -f f32le rec.f32
// PART is soprano, alto, tenor, bass or auto.

let args = CommandLine.arguments
guard args.count >= 4 else {
    print("usage: singit-replay AUDIO.f32 HYMN.json PART [VERSE] [--every SECONDS]")
    exit(2)
}
let audio = try Data(contentsOf: URL(fileURLWithPath: args[1]))
let samples = audio.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
let hymn = try Hymn.decode(from: Data(contentsOf: URL(fileURLWithPath: args[2])))
let part = Part(rawValue: args[3])
let verse = args.count > 4 ? Int(args[4]) ?? 1 : 1
let every = args.firstIndex(of: "--every").flatMap { Double(args[$0 + 1]) } ?? 0.25

let sampleRate = 16_000.0
let detector = PitchDetector(sampleRate: sampleRate)
func option(_ name: String) -> String? { args.firstIndex(of: name).map { args[$0 + 1] } }
let beatMap = try option("--beatmap").map { try BeatMap.decode(from: Data(contentsOf: URL(fileURLWithPath: $0))) }
let session = SingingSession(hymn: hymn, part: part, startVerse: verse, anyOctave: !args.contains("--exact"),
                             steadyTempo: !args.contains("--alone"), octaveShift: option("--octave").flatMap { Int($0) } ?? 0)
let frameLength = Int(sampleRate * 0.064), hop = Int(sampleRate * 0.02)

if args.contains("--onsets") {
    // Just list syllable starts and the pitch that followed, for studying a recording.
    var onsets = OnsetDetector()
    var start = 0
    var out: [String] = []
    while start + frameLength <= samples.count {
        let frame = Array(samples[start..<start + frameLength])
        let pitch = detector.estimate(frame)
        var energy: Float = 0
        for x in frame[(frameLength - hop)...] { energy += x * x }
        let level = 10 * log10(Double(energy / Float(hop)) + 1e-12)
        if onsets.step(voiced: pitch != nil, level: level, dt: 0.02) {
            out.append(String(format: "%.2f", Double(start + frameLength) / sampleRate))
        }
        start += hop
    }
    print("\(out.count) onsets: " + out.joined(separator: " "))
    exit(0)
}

let csv = args.contains("--csv")  // t,position for every 20 ms frame, for scoring against ground truth
if !csv { print("t(s)   sung        pos(beat)  conf  bpm  target  lyric") }
var next = 0.0
var start = 0
while start + frameLength <= samples.count {
    let pitch = detector.estimate(Array(samples[start..<start + frameLength]))
    if let beatMap {
        let mid = Double(start + frameLength / 2) / sampleRate
        let beat = beatMap.beat(atTime: mid)
        session.setMusicClock(beat: beat, rate: beatMap.beat(atTime: mid + 1) - beat)
        session.process(pitch: pitch, dt: 0.02, knownBeat: beat)
    } else {
        session.process(pitch: pitch, dt: 0.02)
    }
    let t = Double(start) / sampleRate
    if csv {
        print(String(format: "%.2f,%.3f", t + 0.064, session.live.position))
    } else if t >= next {
        next += every
        let live = session.live
        let performance = session.performance
        let sung = pitch.map { String(format: "%-5@ %+4.0f¢", NoteName.name(Int($0.midi.rounded())), ($0.midi - $0.midi.rounded()) * 100) } ?? "   –      "
        let target = live.noteIndex.flatMap { performance.notes[$0].midi }.map(NoteName.name) ?? "rest"
        let lyric = performance.syllableIndex(at: live.position).map { performance.syllables[$0].text } ?? ""
        print(String(format: "%5.2f  %@  %7.2f   %.2f  %3.0f  %-6@  %@%@", t, sung, live.position, live.confidence,
                     live.tempo, target, lyric, live.partIsGuess ? "  (\(live.part.rawValue)?)" : " [\(live.part.rawValue)]"))
    }
    start += hop
}
if csv { exit(0) }
let summary = session.summary()
print(String(format: "score %.0f  in tune %d/%d  tendency %+.0f¢", summary.score, summary.inTuneNotes,
             summary.scoredNotes, summary.tendencyCents))
if let lag = summary.musicLag { print(String(format: "music lag %.2f s", lag)) }
if let octaves = summary.octaves {
    print("octaves: " + octaves.map { "\($0.octave): \(Int(($0.share * 100).rounded()))%" }.joined(separator: "  ")
          + "   changes: \(summary.octaveChangeCount ?? 0)")
    for c in summary.octaveChanges ?? [] { print("  \(c.kind) v\(c.verse.map(String.init) ?? "-") '\(c.lyric ?? "")' \(c.from) -> \(c.to)") }
}
for spot in summary.recurring ?? [] {
    print("recurring: \(spot.kind) \(spot.pitch) \(spot.lyrics) missed \(spot.timesMissed)/\(spot.timesSung) "
          + "\(Int(spot.meanCents))¢ (±\(Int(spot.meanAbsCents ?? 0))¢) wrong octave \(spot.wrongOctave.map(String.init) ?? "-")  line \(spot.lineStart)-\(spot.lineEnd) '\(spot.lineText)'")
}
if let counts = summary.pitchCounts, let range = VoiceRange.from(pitchCounts: counts) {
    print("voice range from this session: \(range.text)")
    for fit in VoiceFit.options(for: hymn, range: range).prefix(3) {
        print("  fit: \(fit.label) \(Int((fit.inRange * 100).rounded()))%  too high \(fit.notesTooHigh), too low \(fit.notesTooLow)")
    }
}
