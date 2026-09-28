import AVFoundation

/// Captures the microphone: delivers 16 kHz mono samples for analysis, and records the
/// singing at full quality to an AAC file. In practice mode it also plays the hymn's
/// accompaniment through the same engine and says which moment of the music each block
/// of singing went with.
final class AudioCapture {
    enum CaptureError: LocalizedError {
        case noPermission
        case noConverter

        var errorDescription: String? {
            switch self {
            case .noPermission: "Microphone access is off. Turn it on in Settings › Sing It."
            case .noConverter: "This microphone's audio format isn't supported."
            }
        }
    }

    /// Called on a background queue with each block of 16 kHz mono samples and, when music
    /// is playing, the time in the recording (seconds) the block's first sample was sung
    /// against: what the singer was hearing, allowing for output and input delays.
    var onSamples: (@Sendable ([Float], Double?) -> Void)?
    /// Called on the main queue if audio stops unexpectedly (a call, a headset unplugged).
    var onInterrupted: ((String) -> Void)?
    /// Called on the main queue for something worth telling the singer that doesn't stop listening.
    var onNotice: ((String) -> Void)?
    /// Called on the main queue when the accompaniment reaches its end.
    var onMusicFinished: (() -> Void)?

    static let analysisFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                              channels: 1, interleaved: false)!

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    /// The singer's own line, rendered on the recording's timeline (see `PartSynth`).
    private let partPlayer = AVAudioPlayerNode()
    private var part: AVAudioPCMBuffer?
    private let queue = DispatchQueue(label: "SingIt.audio-analysis")
    private var converter: AVAudioConverter?
    private var downmix: AVAudioConverter?
    private var file: AVAudioFile?
    private var music: AVAudioFile?
    /// Seconds into the music where the current playback segment began.
    private var musicSegmentStart = 0.0
    /// Seconds from the music being rendered to the singer's voice reaching this app.
    private var roundTrip = 0.0
    /// Bumped whenever playback is rescheduled, so stale completion callbacks are ignored.
    private var musicGeneration = 0
    private var observers: [NSObjectProtocol] = []
    private(set) var isRunning = false

    init() {
        engine.attach(player)
        engine.attach(partPlayer)
    }

    /// Accompaniment loudness, 0...1 (0 leaves only the singer's part, if one is playing).
    var accompanimentVolume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    /// - Parameters:
    ///   - voiceProcessing: Apple's voice processing (noise suppression, gain control and
    ///     echo cancellation). Helps with the phone's own mic in a noisy room; a headset
    ///     mic works better without it. Always on when music plays through the speaker,
    ///     so the mic doesn't hear the accompaniment.
    ///   - music: an accompaniment to play, starting `musicStart` seconds in.
    ///   - part: the singer's line on the same timeline, played alongside it.
    func start(voiceProcessing: Bool, recordTo url: URL?, music musicURL: URL? = nil, musicStart: Double = 0,
               part: AVAudioPCMBuffer? = nil) throws {
        guard !isRunning else { return }
        guard AVAudioApplication.shared.recordPermission == .granted else { throw CaptureError.noPermission }

        let session = AVAudioSession.sharedInstance()
        if musicURL != nil {
            // Music in the headphones at full quality (Bluetooth A2DP); the phone's mic listens.
            try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothA2DP, .defaultToSpeaker])
        } else {
            try session.setCategory(.playAndRecord, mode: voiceProcessing ? .voiceChat : .measurement,
                                    options: [.allowBluetoothHFP, .defaultToSpeaker])
        }
        try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true)

        var processing = voiceProcessing
        if musicURL != nil, session.currentRoute.outputs.contains(where: { $0.portType == .builtInSpeaker }) {
            processing = true  // cancel the accompaniment's echo from the speaker
        }
        let input = engine.inputNode
        if input.isVoiceProcessingEnabled != processing {
            try input.setVoiceProcessingEnabled(processing)
        }
        // Record mono AAC at the hardware rate. No fixed bit rate: Bluetooth headset mics run
        // at 8-24 kHz, where a high AAC bit rate is refused.
        let rate = input.outputFormat(forBus: 0).sampleRate
        if let url {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: 1,
            ]
            file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        }
        if let musicURL {
            let music = try AVAudioFile(forReading: musicURL)
            self.music = music
            engine.connect(player, to: engine.mainMixerNode, format: music.processingFormat)
            self.part = part
            if let part { engine.connect(partPlayer, to: engine.mainMixerNode, format: part.format) }
        } else {
            music = nil
            self.part = nil
        }
        roundTrip = session.outputLatency + session.inputLatency + session.ioBufferDuration
        do {
            try startEngine()
            if music != nil { playMusic(from: musicStart) }
        } catch {
            file = nil
            throw error
        }
        isRunning = true
        observe(session)
    }

    /// Where the music is now (seconds), if it's playing.
    var musicPosition: Double? {
        guard music != nil, let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else { return nil }
        return musicSegmentStart + Double(playerTime.sampleTime) / playerTime.sampleRate
    }

    /// Where the music is at this moment (seconds), for drawing: the player's last render
    /// moved on by the time since, so it advances smoothly between render cycles.
    var musicTimeNow: Double? {
        guard music != nil, let nodeTime = player.lastRenderTime, nodeTime.isHostTimeValid,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else { return nil }
        let since = AVAudioTime.seconds(forHostTime: mach_absolute_time()) - AVAudioTime.seconds(forHostTime: nodeTime.hostTime)
        return musicSegmentStart + Double(playerTime.sampleTime) / playerTime.sampleRate + min(max(since, 0), 0.25)
    }

    /// Seconds from the player to the singer's ears (large over Bluetooth).
    var outputLatency: Double { AVAudioSession.sharedInstance().outputLatency }

    /// Jump the music to `seconds` without stopping the microphone.
    func seekMusic(to seconds: Double) {
        guard music != nil, isRunning else { return }
        playMusic(from: seconds)
    }

    private func playMusic(from seconds: Double) {
        guard let music else { return }
        musicGeneration += 1
        let generation = musicGeneration
        player.stop()
        partPlayer.stop()
        let rate = music.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(max(0, seconds) * rate)
        guard startFrame < music.length else { return }
        musicSegmentStart = Double(startFrame) / rate
        player.scheduleSegment(music, startingFrame: startFrame, frameCount: AVAudioFrameCount(music.length - startFrame),
                               at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.isRunning, generation == self.musicGeneration else { return }
                self.onMusicFinished?()
            }
        }
        if let part, let rest = slice(part, from: musicSegmentStart) {
            partPlayer.scheduleBuffer(rest, at: nil)
            // Start both at the same moment so the line stays locked to the recording.
            let start = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.05))
            player.play(at: start)
            partPlayer.play(at: start)
        } else {
            player.play()
        }
    }

    /// The part from `seconds` on (buffers can't be scheduled from the middle).
    private func slice(_ buffer: AVAudioPCMBuffer, from seconds: Double) -> AVAudioPCMBuffer? {
        let start = Int(seconds * buffer.format.sampleRate)
        guard start < Int(buffer.frameLength), let source = buffer.floatChannelData else { return nil }
        let count = AVAudioFrameCount(Int(buffer.frameLength) - start)
        guard let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: count),
              let destination = out.floatChannelData else { return nil }
        out.frameLength = count
        destination[0].update(from: source[0] + start, count: Int(count))
        return out
    }

    /// (Re)builds the converters for the input's current format, installs the tap and starts.
    private func startEngine() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: format, to: Self.analysisFormat) else {
            throw CaptureError.noConverter
        }
        self.converter = converter
        let recordFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate,
                                         channels: 1, interleaved: false)!
        downmix = format.channelCount == 1 ? nil : AVAudioConverter(from: format, to: recordFormat)

        input.removeTap(onBus: 0)  // installing a second tap raises an exception
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        musicGeneration += 1
        player.stop()
        partPlayer.stop()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        queue.sync { file = nil }  // closes the file
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        // What the singer was hearing when this block's first sample was sung: the music
        // playing now, less the block's length and the round trip through the speakers or
        // headphones and back through the mic.
        let heard = musicPosition.map { $0 - Double(buffer.frameLength) / buffer.format.sampleRate - roundTrip }

        let ratio = Self.analysisFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.analysisFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = out.floatChannelData?[0] else { return }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))

        // The tap's buffer can be reused once this returns, so write a copy.
        let recordBuffer = downmix.flatMap { mono(buffer, with: $0) } ?? copy(buffer)
        queue.async { [weak self] in
            if let recordBuffer { try? self?.file?.write(from: recordBuffer) }
            self?.onSamples?(samples, heard)
        }
    }

    private func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
              let src = buffer.floatChannelData, let dst = out.floatChannelData else { return nil }
        out.frameLength = buffer.frameLength
        for ch in 0..<Int(buffer.format.channelCount) {
            dst[ch].update(from: src[ch], count: Int(buffer.frameLength))
        }
        return out
    }

    private func mono(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        guard let out = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: buffer.frameLength) else {
            return nil
        }
        var supplied = false
        converter.convert(to: out, error: nil) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        return out
    }

    private func observe(_ session: AVAudioSession) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session,
                                            queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            if type == .began {
                self?.stop()
                self?.onInterrupted?("Listening stopped because of an interruption (a call or another app).")
            }
        })
        // A headset plugged in or removed (or voice processing settling) changes the input
        // format; the engine stops itself, so rebuild and restart it (and the music).
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                            queue: .main) { [weak self] _ in
            guard let self, self.isRunning, !self.engine.isRunning else { return }
            let recordingRate = self.queue.sync { self.file?.processingFormat.sampleRate }
            let resumeAt = self.musicPosition
            do {
                try self.startEngine()
                let session = AVAudioSession.sharedInstance()
                self.roundTrip = session.outputLatency + session.inputLatency + session.ioBufferDuration
                if let resumeAt { self.playMusic(from: resumeAt) }
                let rate = self.engine.inputNode.outputFormat(forBus: 0).sampleRate
                if let recordingRate, rate != recordingRate {
                    self.queue.sync { self.file = nil }
                    self.onNotice?("The microphone changed, so recording stopped. Listening continues.")
                }
            } catch {
                self.stop()
                self.onInterrupted?("The microphone changed and listening stopped. Tap Resume.")
            }
        })
    }
}
