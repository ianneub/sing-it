import Foundation
import Observation
import SingItCore

/// What the app knows about the singer's voice: pitches sung across sessions, and the
/// result of the range check if they've done one (which takes precedence).
@Observable
final class VoiceProfile {
    private(set) var pitchCounts: [Int]
    private(set) var checkedRange: VoiceRange?
    private(set) var sessions: Int

    private static let key = "voiceProfile"

    private struct Stored: Codable {
        var pitchCounts: [Int]
        var checkedRange: VoiceRange?
        var sessions: Int
    }

    init() {
        let stored = UserDefaults.standard.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        let size = SessionSummary.pitchCountRange.count
        pitchCounts = stored?.pitchCounts.count == size ? stored!.pitchCounts : [Int](repeating: 0, count: size)
        checkedRange = stored?.checkedRange
        sessions = stored?.sessions ?? 0
    }

    /// The comfortable range: from the range check, else learned from singing.
    var range: VoiceRange? { checkedRange ?? VoiceRange.from(pitchCounts: pitchCounts) }

    var rangeSource: String {
        if checkedRange != nil { return "from your range check" }
        return sessions == 1 ? "learned from 1 session" : "learned from \(sessions) sessions"
    }

    func add(_ summary: SessionSummary) {
        guard let counts = summary.pitchCounts, counts.count == pitchCounts.count, counts.reduce(0, +) > 0 else { return }
        for i in counts.indices { pitchCounts[i] += counts[i] }
        sessions += 1
        save()
    }

    func setChecked(_ range: VoiceRange?) {
        checkedRange = range
        save()
    }

    private func save() {
        let stored = Stored(pitchCounts: pitchCounts, checkedRange: checkedRange, sessions: sessions)
        if let data = try? JSONEncoder().encode(stored) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}
