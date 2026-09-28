import AVFoundation
import SingItCore
import SwiftUI

/// Past sessions: listen back, share, or delete.
struct RecordingsView: View {
    @State private var recordings: [Recording] = []
    @State private var player: AVAudioPlayer?
    @State private var playing: Recording?
    @State private var summary: SessionSummary?

    var body: some View {
        List {
            ForEach(recordings) { recording in
                HStack {
                    Button {
                        toggle(recording)
                    } label: {
                        Image(systemName: playing == recording ? "stop.circle.fill" : "play.circle.fill")
                            .font(.title)
                    }
                    .buttonStyle(.borderless)

                    VStack(alignment: .leading) {
                        Text(recording.title)
                            .font(.subheadline)
                            .lineLimit(2)
                        if let s = recording.summary() {
                            Text("\(Int(s.score.rounded()))% · \(s.inTuneNotes)/\(s.scoredNotes) notes in tune")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if let s = recording.summary() {
                        Button {
                            summary = s
                        } label: {
                            Image(systemName: "chart.bar")
                        }
                        .buttonStyle(.borderless)
                    }
                    ShareLink(item: recording.audio) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderless)
                }
            }
            .onDelete { offsets in
                for i in offsets { RecordingStore.delete(recordings[i]) }
                recordings.remove(atOffsets: offsets)
            }
        }
        .overlay {
            if recordings.isEmpty {
                ContentUnavailableView("No recordings yet", systemImage: "waveform",
                                       description: Text("Each time you sing, the audio is saved here."))
            }
        }
        .navigationTitle("Recordings")
        .onAppear { recordings = RecordingStore.all() }
        .onDisappear { player?.stop() }
        .sheet(item: $summary) { SummaryView(summary: $0) }
    }

    private func toggle(_ recording: Recording) {
        if playing == recording {
            player?.stop()
            playing = nil
            return
        }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
            player = try AVAudioPlayer(contentsOf: recording.audio)
            player?.play()
            playing = recording
        } catch {
            playing = nil
        }
    }
}
