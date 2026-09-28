import Foundation

/// Where each beat falls in a recording of a hymn (the Church's accompaniment MP3), made
/// by `tools/beatmap.py`. Beats are performance beats (every pass of the form back to
/// back, as in `Performance`); the recording starts with the organ introduction.
public struct BeatMap: Decodable, Sendable {
    /// Where the app downloads the recording.
    public let url: URL
    public let duration: Double
    /// Seconds into the recording where singing (beat 0) starts; before it is the introduction.
    public let singingStart: Double
    /// [seconds, beat] pairs, every eighth of a beat.
    public let beats: [[Double]]

    public static func decode(from data: Data) throws -> BeatMap {
        try JSONDecoder().decode(BeatMap.self, from: data)
    }

    /// The performance beat at `seconds` into the recording. Negative during the
    /// introduction (counting up to 0 at the first sung note).
    public func beat(atTime seconds: Double) -> Double {
        guard let first = beats.first, let last = beats.last, beats.count > 1 else { return 0 }
        if seconds <= first[0] {
            return first[1] - (first[0] - seconds) * rate(0)
        }
        if seconds >= last[0] {
            return last[1] + (seconds - last[0]) * rate(beats.count - 2)
        }
        var lo = 0, hi = beats.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if beats[mid][0] <= seconds { lo = mid } else { hi = mid }
        }
        let (t0, b0, t1, b1) = (beats[lo][0], beats[lo][1], beats[hi][0], beats[hi][1])
        return t1 > t0 ? b0 + (seconds - t0) / (t1 - t0) * (b1 - b0) : b0
    }

    /// Seconds into the recording where `beat` is played.
    public func time(atBeat beat: Double) -> Double {
        guard let first = beats.first, let last = beats.last, beats.count > 1 else { return singingStart }
        if beat <= first[1] { return first[0] - (first[1] - beat) / rate(0) }
        if beat >= last[1] { return last[0] + (beat - last[1]) / rate(beats.count - 2) }
        var lo = 0, hi = beats.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if beats[mid][1] <= beat { lo = mid } else { hi = mid }
        }
        let (t0, b0, t1, b1) = (beats[lo][0], beats[lo][1], beats[hi][0], beats[hi][1])
        return b1 > b0 ? t0 + (beat - b0) / (b1 - b0) * (t1 - t0) : t0
    }

    /// Beats per second around point `i`, averaged over a few beats.
    private func rate(_ i: Int) -> Double {
        let a = max(0, min(i, beats.count - 1)), b = min(beats.count - 1, a + 16)
        guard b > a, beats[b][0] > beats[a][0] else { return 1.5 }
        return (beats[b][1] - beats[a][1]) / (beats[b][0] - beats[a][0])
    }
}
