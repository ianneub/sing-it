import AVFoundation
import SingItCore
import SwiftUI

/// Past sessions: listen back, share, or delete.
struct RecordingsView: View {
    @State private var recordings: [Recording] = []
    @State private var playback = Playback()
    @State private var summary: SessionSummary?

    var body: some View {
        List {
            ForEach(recordings) { recording in
                HStack {
                    Button {
                        playback.toggle(recording)
                    } label: {
                        Image(systemName: playback.playing == recording ? "stop.circle.fill" : "play.circle.fill")
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
                for i in offsets {
                    if playback.playing == recordings[i] { playback.stop() }
                    RecordingStore.delete(recordings[i])
                }
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
        .onDisappear { playback.stop() }
        .sheet(item: $summary) { SummaryView(summary: $0) }
    }

}

/// Plays one recording at a time: starting another stops the one playing.
@MainActor
@Observable
final class Playback: NSObject, AVAudioPlayerDelegate {
    private(set) var playing: Recording?
    private var player: AVAudioPlayer?

    func toggle(_ recording: Recording) {
        let wasPlaying = playing
        stop()
        guard wasPlaying != recording else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
            let player = try AVAudioPlayer(contentsOf: recording.audio)
            player.delegate = self
            player.play()
            self.player = player
            playing = recording
        } catch {
            playing = nil
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playing = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finished = ObjectIdentifier(player)
        Task { @MainActor in
            if let current = self.player, ObjectIdentifier(current) == finished { self.stop() }
        }
    }
}
