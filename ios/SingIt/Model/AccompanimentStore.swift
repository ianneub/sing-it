import Foundation
import SingItCore

/// The Church's accompaniment recordings, downloaded the first time a hymn is practised
/// and kept in Caches (iOS may clear them when space is short; they're fetched again).
enum AccompanimentStore {
    static var folder: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let folder = caches.appendingPathComponent("Accompaniment", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func localURL(for hymn: Hymn) -> URL {
        folder.appendingPathComponent("\(hymn.number).mp3")
    }

    static func isDownloaded(_ hymn: Hymn) -> Bool {
        FileManager.default.fileExists(atPath: localURL(for: hymn).path)
    }

    /// The recording on disk, downloading it first if needed.
    static func file(for hymn: Hymn, map: BeatMap) async throws -> URL {
        let destination = localURL(for: hymn)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        let (temporary, response) = try await URLSession.shared.download(from: map.url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }
}
