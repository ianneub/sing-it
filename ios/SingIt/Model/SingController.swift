import AVFoundation
import Foundation
import Observation
import SingItCore
import UIKit

/// What plays in practice mode.
enum MusicMix: String {
    case full           // the accompaniment
    case withPart       // the accompaniment with the singer's line on top
    case partOnly       // the introduction or lead-in, then only the singer's line
}

/// Drives one singing session: the microphone feeds a `SingingSession` on a background
/// queue, and the screen refreshes from it about 30 times a second. With a beat map, it's
/// practice mode: the app plays the accompaniment and the position comes from the music.
@MainActor
@Observable
final class SingController {
    let hymn: Hymn
    let requestedPart: Part?
    let session: SingingSession
    /// Set in practice mode.
    let beatMap: BeatMap?
    /// Practising one line: the music loops over these beats.
    let loop: ClosedRange<Double>?
    private(set) var loopRounds = 0
    private var lastLoopSeek = Date.distantPast
    private let startVerse: Int
    private let capture = AudioCapture()
    private var refreshTask: Task<Void, Never>?

    private(set) var live: LiveState
    private(set) var performance: Performance
    private(set) var trace: [TracePoint] = []
    private(set) var results: [Int: NoteResult] = [:]
    private(set) var isListening = false
    private(set) var isDownloading = false
    private var isStarting = false
    /// Where to resume the music after a pause (seconds).
    private var musicResumeAt: Double?
    let musicMix: MusicMix
    /// The singer's line rendered for playback, made once when first needed.
    private var partBuffer: AVAudioPCMBuffer?
    /// With `.partOnly`, the accompaniment plays until this point (seconds): the
    /// introduction or a lead-in, so the singer hears where to come in.
    private var accompanimentUntil = 0.0
    private(set) var recordingURL: URL?
    var message: String?

    /// Beats shown before and after the current position in the note display.
    let lookBehind = 3.0
    let lookAhead = 7.0

    init(hymn: Hymn, part: Part?, verse: Int, tolerance: Double, anyOctave: Bool, octaveShift: Int = 0,
         coachOctave: Bool = false,
         steadyTempo: Bool, beatMap: BeatMap? = nil, loop: ClosedRange<Double>? = nil, musicMix: MusicMix = .full) {
        self.hymn = hymn
        self.requestedPart = part
        self.beatMap = beatMap
        self.loop = loop
        // Auto and Any part have no single line to play.
        self.musicMix = part == nil || part == .anyPart ? .full : musicMix
        self.startVerse = verse
        let session = SingingSession(hymn: hymn, part: part, startVerse: verse, tolerance: tolerance,
                                     anyOctave: anyOctave, steadyTempo: steadyTempo, octaveShift: octaveShift,
                                     coachOctave: coachOctave)
        if let loop { session.jump(to: loop.lowerBound) }
        self.session = session
        self.live = session.live
        self.performance = session.performance
        capture.onSamples = { [session, beatMap] samples, heard in
            if let beatMap, let heard { session.setMusicClock(time: heard, beatMap: beatMap) }
            session.process(samples)
        }
        capture.onMusicFinished = { [weak self] in
            self?.pause()
            self?.message = "That's the end of the accompaniment. Tap Done to see how you did."
        }
        capture.onNotice = { [weak self] notice in self?.message = notice }
        capture.onInterrupted = { [weak self] reason in
            self?.isListening = false
            self?.message = reason
            self?.stopRefreshing()
        }
    }

    func start(voiceProcessing: Bool) async {
        guard !isListening, !isStarting else { return }  // ignore a double tap on Start
        isStarting = true
        defer { isStarting = false }
        guard await AudioCapture.requestPermission() else {
            message = AudioCapture.CaptureError.noPermission.errorDescription
            return
        }
        do {
            var music: URL?
            if let beatMap {
                isDownloading = !AccompanimentStore.isDownloaded(hymn)
                defer { isDownloading = false }
                music = try await AccompanimentStore.file(for: hymn, map: beatMap)
            }
            if let beatMap, musicMix != .full, partBuffer == nil {
                let performance = session.performance
                let samples = await Task.detached { PartSynth.render(performance, beatMap: beatMap, sampleRate: 22_050) }.value
                partBuffer = Self.buffer(samples, sampleRate: 22_050)
            }
            let from = musicResumeAt ?? practiceStart
            accompanimentUntil = musicResumeAt.map { $0 + 1 } ?? practiceEntry
            // Each start (including a resume) records to its own file.
            let url = RecordingStore.newURL(hymn: hymn, part: requestedPart)
            try capture.start(voiceProcessing: voiceProcessing, recordTo: url, music: music, musicStart: from,
                              part: musicMix == .full ? nil : partBuffer)
            recordingURL = url
            isListening = true
            message = nil
            UIApplication.shared.isIdleTimerDisabled = true
            startRefreshing()
        } catch {
            message = error.localizedDescription
        }
    }

    /// Stops listening and returns the results, saving them beside the recording.
    @discardableResult
    func finish() -> SessionSummary {
        capture.stop()
        isListening = false
        stopRefreshing()
        refresh()
        let summary = session.summary()
        if let recordingURL { RecordingStore.save(summary, for: recordingURL) }
        return summary
    }

    func pause() {
        if let position = capture.musicPosition { musicResumeAt = max(0, position - 1) }
        capture.stop()
        isListening = false
        stopRefreshing()
    }

    private static func buffer(_ samples: [Float], sampleRate: Double) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1,
                                         interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel[0].update(from: $0.baseAddress!, count: samples.count) }
        return buffer
    }

    /// Where the singer comes in (seconds): after the introduction, or at the chosen verse
    /// or practice line.
    private var practiceEntry: Double {
        guard let beatMap else { return 0 }
        if let loop { return beatMap.time(atBeat: loop.lowerBound) }
        return beatMap.time(atBeat: performance.start(ofVerse: startVerse))
    }

    /// Where the music starts: the introduction for verse 1, otherwise two beats before
    /// the chosen verse (a short lead-in).
    private var practiceStart: Double {
        guard let beatMap else { return 0 }
        if let loop { return max(0, beatMap.time(atBeat: loop.lowerBound - 2)) }
        let start = performance.start(ofVerse: startVerse)
        return start == 0 ? 0 : max(0, beatMap.time(atBeat: start - 2))
    }

    func choose(_ part: Part) {
        session.choose(part)
        refresh()
    }

    /// Jump to the start of a lyric line (the singer lost their place, or skipped ahead).
    func jump(toLine index: Int) {
        guard performance.lines.indices.contains(index) else { return }
        let beat = performance.lines[index].start
        session.jump(to: beat)
        if let beatMap {  // move the music there too, with a one-beat lead-in
            let time = max(0, beatMap.time(atBeat: beat - 1))
            accompanimentUntil = beatMap.time(atBeat: beat)
            if isListening { capture.seekMusic(to: time) } else { musicResumeAt = time }
        }
        refresh()
    }

    func jump(toBeat beat: Double) {
        session.jump(to: beat)
        refresh()
    }

    private func startRefreshing() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(nanoseconds: 33_000_000)
            }
        }
    }

    private func stopRefreshing() {
        refreshTask?.cancel()
        refreshTask = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    #if DEBUG
    private var demoTask: Task<Void, Never>?

    /// Screenshot mode's demo: advance through `from...to` beats in real time, handing each
    /// stretch to `sing` to feed the session, and refresh the screen as when listening.
    func runDemo(from start: Double, to end: Double, rate: Double, sing: @escaping (Double, Double) -> Void) {
        isListening = true
        startRefreshing()
        demoTask = Task { [weak self] in
            let clock = ContinuousClock(), began = clock.now
            var beat = start
            while beat < end, !Task.isCancelled, self != nil {
                try? await Task.sleep(nanoseconds: 20_000_000)
                let elapsed = clock.now - began
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                let next = min(end, start + seconds * rate)
                sing(beat, next)
                beat = next
            }
        }
    }

    /// Screenshot mode: show the session's current state as if listening.
    func showForScreenshot() {
        refresh()
        isListening = true
    }
    #endif

    /// The beat to draw: with the accompaniment, where the music is in the singer's ears,
    /// read from the beat map at this moment (the note roll asks every screen frame, so it
    /// scrolls smoothly), `lag` seconds earlier for where the singer is. Otherwise, and
    /// while paused, the session's position.
    func displayPosition(lag: Double = 0) -> Double {
        if let beatMap, isListening, let now = capture.musicTimeNow {
            return beatMap.beat(atTime: now - capture.outputLatency - lag)
        }
        return live.position
    }

    /// `displayPosition()` as of the last refresh, for the words.
    private(set) var displayedBeat = 0.0

    private func refresh() {
        live = session.live
        displayedBeat = displayPosition()
        // Practising a line: once the music passes its end, go back to two beats before it.
        // My part only: the accompaniment for the introduction or lead-in, then just the line.
        if musicMix == .partOnly, let position = capture.musicPosition {
            capture.accompanimentVolume = position < accompanimentUntil ? 1 : 0
        } else if musicMix == .withPart {
            capture.accompanimentVolume = 0.7
        }
        if let loop, let beatMap, isListening, live.position > loop.upperBound + 0.25,
           Date().timeIntervalSince(lastLoopSeek) > 1 {
            lastLoopSeek = Date()
            capture.seekMusic(to: max(0, beatMap.time(atBeat: loop.lowerBound - 2)))
            loopRounds += 1
            message = "Round \(loopRounds + 1)"
        }
        if live.part != performance.part { performance = session.performance }
        trace = session.trace(from: live.position - lookBehind - 1, to: live.position + 1)
        results = session.results
    }
}
