import Foundation
import SingItCore

/// Recordings live in Documents/Recordings (visible in the Files app): an .m4a of the
/// singing and a .json summary with the same name.
struct Recording: Identifiable, Hashable {
    let audio: URL
    let date: Date
    var id: URL { audio }
    var summaryURL: URL { audio.deletingPathExtension().appendingPathExtension("json") }
    var title: String { audio.deletingPathExtension().lastPathComponent }

    func summary() -> SessionSummary? {
        guard let data = try? Data(contentsOf: summaryURL) else { return nil }
        return try? JSONDecoder().decode(SessionSummary.self, from: data)
    }
}

enum RecordingStore {
    static var folder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = docs.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// e.g. "2026-09-28 10.04.12 · 2 The Spirit of God (Bass).m4a"
    static func newURL(hymn: Hymn, part: Part?) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let name = "\(formatter.string(from: Date())) · \(hymn.number) \(hymn.title) (\(part?.displayName ?? "Auto"))"
            .replacingOccurrences(of: "/", with: "-")
        return folder.appendingPathComponent(name).appendingPathExtension("m4a")
    }

    static func save(_ summary: SessionSummary, for audio: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(summary).write(to: audio.deletingPathExtension().appendingPathExtension("json"))
    }

    static func all() -> [Recording] {
        let keys: [URLResourceKey] = [.creationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        return urls.filter { $0.pathExtension == "m4a" }
            .map { url in
                let date = (try? url.resourceValues(forKeys: Set(keys)).creationDate) ?? .distantPast
                return Recording(audio: url, date: date)
            }
            .sorted { $0.date > $1.date }
    }

    static func delete(_ recording: Recording) {
        try? FileManager.default.removeItem(at: recording.audio)
        try? FileManager.default.removeItem(at: recording.summaryURL)
    }
}
