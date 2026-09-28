import SingItCore
import SwiftUI

/// The screen used while singing: scrolling notes with your pitch trace, a tuning meter,
/// and the words.
struct SingView: View {
    let hymn: Hymn
    let part: Part?
    let verse: Int
    let tolerance: Double
    let anyOctave: Bool
    var octaveShift = 0
    var coachOctave = false
    let steadyTempo: Bool
    let beatMap: BeatMap?
    let voiceProcessing: Bool
    /// Practising one line over and over: its beats and words.
    var loop: (range: ClosedRange<Double>, text: String)?
    var musicMix: MusicMix = .full
    /// A controller made elsewhere (screenshot mode); normally the view makes its own.
    var prepared: SingController?

    @Environment(\.dismiss) private var dismiss
    @Environment(VoiceProfile.self) private var voice
    @State private var controller: SingController?
    @State private var summary: SessionSummary?
    /// A line picked from the summary to practise; presented once the summary closes.
    @State private var practising: SessionSummary.RecurringSpot?
    @State private var showPractice: SessionSummary.RecurringSpot?

    var body: some View {
        Group {
            if let controller {
                content(controller)
            } else {
                ProgressView()
            }
        }
        .onAppear {
            if controller == nil, let prepared {
                controller = prepared
            } else if controller == nil {
                controller = SingController(hymn: hymn, part: part, verse: verse, tolerance: tolerance,
                                            anyOctave: anyOctave, octaveShift: octaveShift, coachOctave: coachOctave,
                                            steadyTempo: steadyTempo,
                                            beatMap: beatMap, loop: loop?.range, musicMix: musicMix)
            }
        }
        .sheet(item: $summary, onDismiss: {
            if let spot = practising {
                practising = nil
                showPractice = spot
            } else {
                dismiss()
            }
        }) { summary in
            SummaryView(summary: summary, practise: beatMap == nil || loop != nil ? nil : { spot in
                practising = spot
                self.summary = nil
            })
        }
        .fullScreenCover(item: $showPractice, onDismiss: { dismiss() }) { spot in
            SingView(hymn: hymn, part: part, verse: verse, tolerance: tolerance, anyOctave: anyOctave,
                     octaveShift: octaveShift, coachOctave: coachOctave, steadyTempo: steadyTempo, beatMap: beatMap,
                     voiceProcessing: voiceProcessing, loop: (spot.lineStart...spot.lineEnd, spot.lineText),
                     musicMix: musicMix)
        }
    }

    private func content(_ c: SingController) -> some View {
        VStack(spacing: 12) {
            header(c)
            if c.live.partIsGuess {
                partBanner(c)
            }
            if let loop {
                Label("Practising “\(loop.text)” — it repeats until you tap Done", systemImage: "repeat")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
            NoteRollView(controller: c)
                .frame(maxHeight: .infinity)
            TuningMeterView(live: c.live, tolerance: tolerance)
            LyricsView(performance: c.performance, position: c.live.position) { line in
                c.jump(toLine: line)
            }
            if let message = c.message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
            controls(c)
        }
        .padding()
    }

    private func header(_ c: SingController) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "\(hymn.number). \(hymn.title)")
                    .font(.headline)
                    .lineLimit(1)
                Text(passLabel(c))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(c.live.scoredNotes > 0 ? "\(Int(c.live.score.rounded()))%" : "–")
                    .font(.title2.bold())
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if c.live.streak >= 3 {
                    Label("\(c.live.streak) in a row", systemImage: "flame.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func passLabel(_ c: SingController) -> String {
        let partName = c.live.part.displayName + (c.live.partIsGuess ? "?" : "")
        if c.live.hint == .intro { return "Introduction · \(partName)" }
        guard let pass = c.performance.pass(at: c.live.position) else { return partName }
        let where_ = pass.verse.map { "Verse \($0)" } ?? pass.kind.capitalized
        return "\(where_) · \(partName)"
    }

    private func partBanner(_ c: SingController) -> some View {
        HStack {
            Image(systemName: "ear")
            Text(c.live.started ? "Sounds like \(c.live.part.displayName)…" : "Sing and I'll find your part")
            Spacer()
            if c.live.started {
                Button("Use \(c.live.part.displayName)") { c.choose(c.live.part) }
                    .buttonStyle(.bordered)
            }
        }
        .font(.subheadline)
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func controls(_ c: SingController) -> some View {
        HStack(spacing: 24) {
            Button {
                if let line = c.performance.lineIndex(at: c.live.position) { c.jump(toLine: max(0, line - 1)) }
            } label: {
                Image(systemName: "backward.fill")
            }
            .accessibilityLabel("Previous line")

            Button {
                if c.isListening {
                    c.pause()
                } else {
                    Task { await c.start(voiceProcessing: voiceProcessing) }
                }
            } label: {
                Label(c.isDownloading ? "Downloading…" : c.isListening ? "Pause" : (c.live.started ? "Resume" : "Start"),
                      systemImage: c.isListening ? "pause.fill" : c.beatMap != nil ? "play.fill" : "mic.fill")
                    .frame(minWidth: 110)
            }
            .buttonStyle(.borderedProminent)
            .tint(c.isListening ? .orange : .accentColor)

            Button {
                if let line = c.performance.lineIndex(at: c.live.position) { c.jump(toLine: line + 1) }
            } label: {
                Image(systemName: "forward.fill")
            }
            .accessibilityLabel("Next line")

            Spacer()

            Button("Done") {
                let result = c.finish()
                voice.add(result)
                summary = result
            }
            .buttonStyle(.bordered)
        }
        .font(.title3)
    }
}
