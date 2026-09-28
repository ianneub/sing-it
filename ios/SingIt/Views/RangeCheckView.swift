import SingItCore
import SwiftUI

/// A quick check of the singer's comfortable range: hold your lowest comfortable note,
/// then your highest. Stored in the voice profile, where it takes precedence over the
/// range learned from sessions.
struct RangeCheckView: View {
    @Environment(VoiceProfile.self) private var voice
    @Environment(\.dismiss) private var dismiss
    @State private var model = RangeCheckModel()

    var body: some View {
        List {
            Section {
                Text("Sing an easy \"ah\" and hold each note for a few seconds. Comfortable, not "
                     + "the most you can squeeze out: the range you can sing a whole hymn in.")
                    .font(.callout)
            }
            step(.low, title: "1. Your lowest comfortable note",
                 prompt: "Slide down until it starts to feel rumbly or weak, then come back up a little and hold.")
            step(.high, title: "2. Your highest comfortable note",
                 prompt: "Slide up until it starts to strain, then come back down a little and hold.")
            if let low = model.low, let high = model.high {
                Section("Your range") {
                    Text("\(NoteName.name(Int(low.rounded()))) to \(NoteName.name(Int(high.rounded())))")
                        .font(.title2.bold())
                    Button("Save") {
                        voice.setChecked(VoiceRange(low: low, high: high))
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            if voice.checkedRange != nil {
                Section {
                    Button("Forget my range check", role: .destructive) {
                        voice.setChecked(nil)
                        dismiss()
                    }
                } footer: {
                    Text("Sing It will go back to learning your range from your singing.")
                }
            }
            if let message = model.message {
                Text(message).foregroundStyle(.orange)
            }
        }
        .navigationTitle("Check my range")
        .onDisappear { model.stop() }
    }

    private func step(_ which: RangeCheckModel.Step, title: String, prompt: String) -> some View {
        Section(title) {
            Text(prompt).font(.callout).foregroundStyle(.secondary)
            HStack {
                if model.listening == which {
                    Text(model.current.map { NoteName.name(Int($0.rounded())) } ?? "…")
                        .font(.title.bold().monospacedDigit())
                    Spacer()
                    ProgressView(value: model.progress)
                        .frame(width: 100)
                } else {
                    let result = which == .low ? model.low : model.high
                    Text(result.map { NoteName.name(Int($0.rounded())) } ?? "–")
                        .font(.title.bold())
                    Spacer()
                    Button(result == nil ? "Start" : "Again") {
                        Task { await model.listen(for: which) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.listening != nil)
                }
            }
        }
    }
}

/// Listens for a few seconds and takes the note the singer held.
@MainActor
@Observable
final class RangeCheckModel {
    enum Step { case low, high }

    private(set) var listening: Step?
    private(set) var current: Double?
    private(set) var progress = 0.0
    private(set) var low: Double?
    private(set) var high: Double?
    private(set) var message: String?

    private let capture = AudioCapture()
    private let collector = PitchCollector()
    private let seconds = 4.0

    func listen(for step: Step) async {
        guard await AudioCapture.requestPermission() else {
            message = AudioCapture.CaptureError.noPermission.errorDescription
            return
        }
        collector.reset()
        capture.onSamples = { [collector] samples, _ in collector.add(samples) }
        do {
            try capture.start(voiceProcessing: false, recordTo: nil)
        } catch {
            message = error.localizedDescription
            return
        }
        listening = step
        message = nil
        let ticks = Int(seconds * 10)
        for tick in 1...ticks {
            try? await Task.sleep(nanoseconds: 100_000_000)
            current = collector.latest
            progress = Double(tick) / Double(ticks)
        }
        capture.stop()
        listening = nil
        // The held note: the middle of the last two seconds, ignoring the slide into it.
        guard let held = collector.heldPitch(lastSeconds: 2) else {
            message = "I couldn't hear a steady note. Try again a little louder, closer to the phone."
            return
        }
        if step == .low { low = held } else { high = held }
    }

    func stop() {
        capture.stop()
    }
}

/// Pitch detection for the range check, fed from the audio queue.
final class PitchCollector: @unchecked Sendable {
    private let detector = PitchDetector(sampleRate: 16_000)
    private let lock = NSLock()
    private var buffer: [Float] = []
    private var pitches: [(time: Double, midi: Double)] = []
    private var time = 0.0

    func reset() {
        lock.withLock {
            buffer.removeAll()
            pitches.removeAll()
            time = 0
        }
    }

    func add(_ samples: [Float]) {
        lock.withLock {
            buffer += samples
            while buffer.count >= 1024 {
                if let p = detector.estimate(Array(buffer[0..<1024])), p.clarity > 0.7 {
                    pitches.append((time, p.midi))
                }
                buffer.removeFirst(320)
                time += 0.02
            }
        }
    }

    var latest: Double? { lock.withLock { pitches.last?.midi } }

    func heldPitch(lastSeconds: Double) -> Double? {
        lock.withLock {
            let recent = pitches.filter { $0.time >= time - lastSeconds }.map(\.midi).sorted()
            guard recent.count >= 25 else { return nil }
            return recent[recent.count / 2]
        }
    }
}
