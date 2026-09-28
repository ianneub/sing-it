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

    /// Sings the melody an octave down up to `endBeat`, the way an untrained singer might:
    /// a little vibrato and drift, a breath at the end of each note, the same slip in the
    /// same place every verse (the third note of the second phrase, three half steps
    /// sharp), and the third phrase of verse 2 two octaves down. (A verse is 72 beats.)
    static func sing(into session: SingingSession, from startBeat: Double = 0, until endBeat: Double) {
        let performance = Performance(hymn: hymn, part: .melody, octaveShift: -1)
        let dt = 0.02, rate = beatMap.beat(atTime: 10) - beatMap.beat(atTime: 9)
        var beat = startBeat, t = startBeat / rate
        while beat < endBeat, let index = performance.noteIndex(at: beat) {
            let note = performance.notes[index]
            var pitch: PitchEstimate?
            if let midi = note.midi, note.end - beat > 0.12 {
                var sung = Double(midi) + 0.15 * sin(2 * .pi * 5.5 * t) + 0.25 * sin(0.9 * t)
                let inVerse = beat.truncatingRemainder(dividingBy: 72)
                if inVerse >= 14 && inVerse < 15 { sung += 3 }
                if beat >= 96 && beat < 112 { sung -= 12 }
                pitch = PitchEstimate(midi: sung, clarity: 0.9)
            }
            session.setMusicClock(beat: beat, rate: rate)
            session.process(pitch: pitch, dt: dt, knownBeat: beat)
            beat += dt * rate
            t += dt
        }
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

    /// Partway through verse 2's second phrase, just after the habitual slip.
    private func prepared(_ controller: SingController) -> SingController {
        ScreenshotMode.sing(into: controller.session, until: 87.6)
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
