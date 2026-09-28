import Foundation

public struct PitchEstimate: Sendable, Equatable {
    public let frequency: Double
    /// 0...1: how periodic the frame is (1 - YIN's aperiodicity at the chosen lag).
    public let clarity: Double

    public init(frequency: Double, clarity: Double) {
        self.frequency = frequency
        self.clarity = clarity
    }

    /// Fractional MIDI note number (A4 = 69).
    public var midi: Double { 69 + 12 * log2(frequency / 440) }

    public init(midi: Double, clarity: Double) {
        self.init(frequency: 440 * pow(2, (midi - 69) / 12), clarity: clarity)
    }
}

/// YIN fundamental-frequency estimator (de Cheveigné & Kawahara, 2002), sized for
/// singing voices: 60 Hz (low bass) to 1100 Hz (high soprano).
public struct PitchDetector: Sendable {
    public let sampleRate: Double
    public var minFrequency: Double = 60
    public var maxFrequency: Double = 1100
    /// Lower = stricter about what counts as a pitched sound.
    public var threshold: Double = 0.15
    /// Frames quieter than this RMS are treated as silence.
    public var silenceRMS: Float = 0.003

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    /// Frame length that covers two periods of the lowest pitch.
    public var frameLength: Int { Int((2 * sampleRate / minFrequency).rounded(.up)) }

    public func estimate(_ frame: [Float]) -> PitchEstimate? {
        let tauMin = max(2, Int(sampleRate / maxFrequency))
        let tauMax = min(Int(sampleRate / minFrequency), frame.count / 2)
        guard tauMax > tauMin + 2 else { return nil }

        var energy: Float = 0
        for x in frame { energy += x * x }
        guard (energy / Float(frame.count)).squareRoot() >= silenceRMS else { return nil }

        // Difference function over a window of W samples.
        let w = frame.count - tauMax
        var diff = [Double](repeating: 0, count: tauMax + 1)
        frame.withUnsafeBufferPointer { x in
            for tau in 1...tauMax {
                var sum: Float = 0
                for j in 0..<w {
                    let d = x[j] - x[j + tau]
                    sum += d * d
                }
                diff[tau] = Double(sum)
            }
        }

        // Cumulative mean normalised difference.
        var cmnd = [Double](repeating: 1, count: tauMax + 1)
        var running = 0.0
        for tau in 1...tauMax {
            running += diff[tau]
            cmnd[tau] = running > 0 ? diff[tau] * Double(tau) / running : 1
        }

        // First dip below the threshold, followed down to its local minimum;
        // otherwise the global minimum if it is still reasonably periodic.
        var chosen: Int?
        var tau = tauMin
        while tau <= tauMax {
            if cmnd[tau] < threshold {
                while tau + 1 <= tauMax && cmnd[tau + 1] < cmnd[tau] { tau += 1 }
                chosen = tau
                break
            }
            tau += 1
        }
        if chosen == nil {
            let best = (tauMin...tauMax).min { cmnd[$0] < cmnd[$1] }!
            if cmnd[best] < 0.35 { chosen = best }
        }
        guard let t = chosen else { return nil }

        // Parabolic interpolation around the minimum for sub-sample accuracy.
        var refined = Double(t)
        if t > tauMin && t < tauMax {
            let a = cmnd[t - 1], b = cmnd[t], c = cmnd[t + 1]
            let denom = a - 2 * b + c
            if denom != 0 { refined += 0.5 * (a - c) / denom }
        }
        return PitchEstimate(frequency: sampleRate / refined, clarity: max(0, min(1, 1 - cmnd[t])))
    }
}
