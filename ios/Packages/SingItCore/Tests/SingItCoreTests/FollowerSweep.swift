import XCTest
@testable import SingItCore

/// Parameter sweep for tuning the follower (prints a table; asserts nothing):
///   SWEEP=1 swift test -c release --filter FollowerSweep
/// Scenarios are untrained singers (`SloppySinger`) across hymns, parts and tempos.
final class FollowerSweep: XCTestCase {
    func testSweep() throws {
        guard ProcessInfo.processInfo.environment["SWEEP"] != nil else { return }
        // (hymn, part, tempo as a fraction of the marked range: 0 = slowest marked, 1 =
        // fastest, below 0 = slower than marked, seed)
        let scenarios: [(String, Part, Double, UInt64)] = [
            ("0002", .tenor, 0.7, 1), ("0002", .soprano, 0.3, 2), ("0006", .bass, 0.5, 3),
            ("0301", .tenor, 0.9, 4), ("0204", .alto, 0.2, 5), ("0027", .soprano, 0.6, 6),
            ("0030", .tenor, 0.4, 7), ("0098", .bass, -0.8, 8),
        ]
        let hymns = try Dictionary(uniqueKeysWithValues: Set(scenarios.map(\.0)).map { ($0, try loadHymn($0)) })
        // Add variations here to compare against the shipped defaults.
        // The shipped defaults in both situations; add variations to compare.
        let grid: [(String, (ScoreFollower) -> Void)] = [
            ("defaults, organ", { $0.diffusion = 3 }),
            ("defaults, alone", { $0.diffusion = 12 }),
        ]
        let jitter = Double(ProcessInfo.processInfo.environment["JITTER"] ?? "0.25")!
        for (name, configure) in grid {
            var line = name.padding(toLength: 26, withPad: " ", startingAt: 0) + "|"
            var means: [Double] = []
            for (prefix, part, bpm, seed) in scenarios {
                let p = Performance(hymn: hymns[prefix]!, part: part)
                var errs: [Double] = []
                for extra in 0..<3 as Range<UInt64> {
                    let session = SingingSession(hymn: hymns[prefix]!, part: part)
                    configure(session.followerForTuning)
                    let marked = hymns[prefix]!.quarterBPMRange
                    let tempo = marked.lowerBound + bpm * (marked.upperBound - marked.lowerBound)
                    let singer = SloppySinger(bpm: tempo, tempoJitter: jitter, seed: seed * 10 + extra)
                    for f in singer.frames(p) {
                        session.process(pitch: f.pitch, dt: f.dt, level: f.level)
                        if f.beat > 4 { errs.append(abs(session.live.position - f.beat)) }
                    }
                }
                let mean = errs.reduce(0, +) / Double(errs.count)
                let within = Double(errs.filter { $0 < 1 }.count) / Double(errs.count)
                means.append(mean)
                line += String(format: " %5.2f/%3.0f%%", mean, within * 100)
            }
            print(line + String(format: " | mean %.2f worst %.2f", means.reduce(0, +) / Double(means.count), means.max()!))
        }
    }
}
