#if DEBUG
import SingItCore
import SwiftUI

/// Debug builds only: launched with `-screenshot <screen>`, the app opens one screen with
/// the made-up test hymn and a simulated singer, for the README's screenshots (see
/// ios/scripts/screenshots.sh). Screens: setup, singing, summary, range, and demo (the
/// singing screen in motion, for the README's animation).
@MainActor
enum ScreenshotMode {
    static var screen: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-screenshot"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static let hymn: Hymn = try! Hymn.decode(from: fixture("test-hymn.json"))
    static let beatMap: BeatMap = try! BeatMap.decode(from: fixture("test-hymn.beatmap.json"))
    /// A man's comfortable range, B♭2–D4.
    static let range = VoiceRange(low: 46, high: 62)

    private static func fixture(_ name: String) -> Data {
        let url = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
        return try! Data(contentsOf: url)
    }

    /// Settings as a man singing the melody an octave down with the app's music would have them.
    static func applySettings(_ voice: VoiceProfile) {
        let defaults = UserDefaults.standard
        defaults.set(Part.melody.rawValue, forKey: "part")
        defaults.set("-1", forKey: "octave")
        defaults.set(false, forKey: "strictOctave")
        defaults.set("app", forKey: "singingWith")
        defaults.set(MusicMix.withPart.rawValue, forKey: "musicMix")
        defaults.set(50.0, forKey: "tolerance")
        voice.setChecked(range)
    }

    static func controller() -> SingController {
        SingController(hymn: hymn, part: .melody, verse: 1, tolerance: 50, anyOctave: true, octaveShift: -1,
                       coachOctave: true, steadyTempo: true, beatMap: beatMap, musicMix: .withPart)
    }

    /// Sings the melody an octave down from `startBeat` to `endBeat` (performance beats,
    /// as the music plays them) like `HumanSinger`, plus the same slip in the same place
    /// every verse (the third note of the second phrase, three half steps sharp) and the
    /// third phrase of verse 2 two octaves down. (A verse is 72 beats.) Calls can pick up
    /// where the last left off: every choice the singer makes is fixed in advance.
    static func sing(into session: SingingSession, from startBeat: Double = 0, until endBeat: Double) {
        let dt = 0.02, rate = beatMap.beat(atTime: 10) - beatMap.beat(atTime: 9)
        var beat = startBeat
        while beat < endBeat {
            session.setMusicClock(beat: beat, rate: rate)
            session.process(pitch: singer.pitch(atMusicBeat: beat, rate: rate), dt: dt, knownBeat: beat)
            beat += dt * rate
        }
    }

    private static let singer = HumanSinger(performance: Performance(hymn: hymn, part: .melody, octaveShift: -1)) {
        beat, midi in
        let inVerse = beat.truncatingRemainder(dividingBy: 72)
        if inVerse >= 14 && inVerse < 15 { return midi + 3 }
        if beat >= 96 && beat < 112 { return midi - 12 }
        return midi
    }
}

/// A simulated singer measured from a real recording of an untrained singer: the melody of
/// a four-verse hymn an octave down (two octaves down for two verses), with the
/// accompaniment. Measured note by note against the hymn in the octave sung:
/// - each note misses by about three quarters of a semitone (standard deviation), about a
///   third of a semitone flat on average, low notes sharp and high notes flat, and a miss
///   carries into the next notes (successive notes' misses correlate 0.4); one note in five
///   is more than a semitone off. Two octaves down the singer was sharper and wilder.
/// - a quarter of notes scoop up from one or two semitones below; a sixth start high;
/// - within a note the pitch wanders slowly (1–2 Hz, about two thirds of a semitone), not
///   a vibrato, with frame-to-frame jitter of a fifth of a semitone;
/// - about one frame in eight is unvoiced, mostly consonants at the starts of notes;
/// - the singing ran about a third of a second behind the music, varying from note to note.
struct HumanSinger {
    private struct Style {
        var miss = 0.0, scoop = 0.0, late = 0.0, silentFrames = 0
        var phases = (0.0, 0.0)
    }

    let performance: Performance
    /// Written pitch → what this singer aims for (slips, octave changes), by music beat.
    let aim: (Double, Double) -> Double
    private let styles: [Style]
    private let lag = 0.3

    init(performance: Performance, seed: UInt64 = 7, aim: @escaping (Double, Double) -> Double = { $1 }) {
        self.performance = performance
        self.aim = aim
        var rng = SplitMix(seed)
        let pitches = performance.notes.compactMap(\.midi).sorted()
        let middle = Double(pitches.isEmpty ? 60 : pitches[pitches.count / 2])
        var drift = 0.0
        styles = performance.notes.map { note in
            var style = Style()
            drift = 0.6 * drift + 0.3 * rng.normal()
            var miss = -0.25 + drift + 0.25 * rng.normal()
            if rng.uniform() < 0.08 { miss += (rng.uniform() < 0.5 ? -1 : 1) * (1 + 0.8 * rng.uniform()) }
            if let midi = note.midi { miss -= 0.1 * (Double(midi) - middle) }
            style.miss = miss
            let start = rng.uniform()
            style.scoop = start < 0.27 ? -(0.8 + 1.2 * rng.uniform())
                : start < 0.43 ? 0.5 + 0.5 * rng.uniform() : 0.2 * rng.normal()
            style.late = max(-0.15, min(0.2, 0.08 * rng.normal()))
            style.silentFrames = rng.uniform() < 0.4 ? 1 + Int(rng.uniform() * 2) : 0
            style.phases = (2 * .pi * rng.uniform(), 2 * .pi * rng.uniform())
            return style
        }
    }

    /// What the singer sings while the music plays `beat`, moving `rate` beats a second.
    func pitch(atMusicBeat beat: Double, rate: Double) -> PitchEstimate? {
        guard let rough = performance.noteIndex(at: beat - lag * rate) else { return nil }
        let sungBeat = beat - (lag + styles[rough].late) * rate
        guard sungBeat >= 0, let index = performance.noteIndex(at: sungBeat) else { return nil }
        let note = performance.notes[index], style = styles[index]
        guard let written = note.midi, note.end - sungBeat > 0.12 else { return nil }  // a breath
        let t = sungBeat / rate, into = (sungBeat - note.start) / rate
        var noise = SplitMix(UInt64(bitPattern: Int64((t * 50).rounded())) &* 0x9E37_79B9)
        if into < Double(style.silentFrames) * 0.02 || noise.uniform() < 0.03 { return nil }
        let target = aim(sungBeat, Double(written))
        // A wrong note learned by habit is sung with conviction; an octave lower than meant
        // is sharper and wilder.
        let habit = (target - Double(written)).truncatingRemainder(dividingBy: 12) != 0
        let wildness = target < Double(written) - 6 ? 1.6 : 1
        var sung = target + (habit ? 0 : (style.miss + (wildness > 1 ? 0.6 : 0)) * wildness)
        sung += style.scoop * exp(-into / 0.15)
        sung += 0.3 * sin(2 * .pi * 0.8 * t + style.phases.0) + 0.2 * sin(2 * .pi * 1.7 * t + style.phases.1)
        sung += 0.14 * noise.normal()
        return PitchEstimate(midi: sung, clarity: 0.85)
    }
}

/// Deterministic random numbers, so the screenshots come out the same every time.
private struct SplitMix {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func normal() -> Double {
        let u = max(uniform(), 1e-12), v = uniform()
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
    }
}

struct ScreenshotRoot: View {
    let screen: String
    @State private var library = HymnLibrary(hymns: [ScreenshotMode.hymn],
                                             beatMaps: [ScreenshotMode.hymn.number: ScreenshotMode.beatMap])
    @State private var voice = VoiceProfile()
    @State private var ready = false

    var body: some View {
        Group {
            if ready { content } else { Color.clear }
        }
        .environment(library)
        .environment(voice)
        .onAppear {
            ScreenshotMode.applySettings(voice)
            ready = true
        }
    }

    @ViewBuilder private var content: some View {
        switch screen {
        case "singing":
            let controller = ScreenshotMode.controller()
            SingView(hymn: ScreenshotMode.hymn, part: .melody, verse: 1, tolerance: 50, anyOctave: true,
                     octaveShift: -1, coachOctave: true, steadyTempo: true, beatMap: ScreenshotMode.beatMap,
                     voiceProcessing: false, musicMix: .withPart, prepared: prepared(controller))
        case "demo":
            let controller = ScreenshotMode.controller()
            SingView(hymn: ScreenshotMode.hymn, part: .melody, verse: 1, tolerance: 50, anyOctave: true,
                     octaveShift: -1, coachOctave: true, steadyTempo: true, beatMap: ScreenshotMode.beatMap,
                     voiceProcessing: false, musicMix: .withPart, prepared: demo(controller))
        case "summary":
            SummaryView(summary: finishedSummary(), practise: { _ in })
        case "range":
            NavigationStack {
                RangeCheckView(model: {
                    let model = RangeCheckModel()
                    model.preset(low: ScreenshotMode.range.low, high: ScreenshotMode.range.high)
                    return model
                }())
            }
        default:
            NavigationStack { HymnSetupView(hymn: ScreenshotMode.hymn) }
        }
    }

    /// Partway through verse 2's second phrase, just after the habitual slip, at a moment
    /// the singer is sounding a note (not taking a breath).
    private func prepared(_ controller: SingController) -> SingController {
        var beat = 87.6
        ScreenshotMode.sing(into: controller.session, until: beat)
        while controller.session.live.meterCents == nil, beat < 90 {
            ScreenshotMode.sing(into: controller.session, from: beat, until: beat + 0.03)
            beat += 0.03
        }
        controller.showForScreenshot()
        return controller
    }

    /// Sings the first few beats straight away, then carries on in real time through the
    /// second phrase and its habitual slip.
    private func demo(_ controller: SingController) -> SingController {
        ScreenshotMode.sing(into: controller.session, until: 6)
        controller.runDemo(from: 6, to: 30, rate: 1.5) { a, b in
            ScreenshotMode.sing(into: controller.session, from: a, until: b)
        }
        return controller
    }

    private func finishedSummary() -> SessionSummary {
        let controller = ScreenshotMode.controller()
        ScreenshotMode.sing(into: controller.session, until: 144)
        return controller.session.summary()
    }
}
#endif
