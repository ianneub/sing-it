import Foundation
import Observation
import SingItCore

/// The hymns bundled with the app (the "json" folder from hymns/json).
@Observable
final class HymnLibrary {
    private(set) var hymns: [Hymn] = []
    private(set) var loadErrors: [String] = []
    /// Beat maps of the accompaniment recordings, by hymn number.
    private(set) var beatMaps: [Int: BeatMap] = [:]

    init(bundle: Bundle = .main) {
        let urls = bundle.urls(forResourcesWithExtension: "json", subdirectory: "json") ?? []
        var hymns: [Hymn] = []
        for url in urls {
            do {
                hymns.append(try Hymn.decode(from: Data(contentsOf: url)))
            } catch {
                loadErrors.append("\(url.lastPathComponent): \(error)")
            }
        }
        self.hymns = hymns.sorted { $0.number < $1.number }
        // Files are named NNNN-slug.json.
        for url in bundle.urls(forResourcesWithExtension: "json", subdirectory: "beatmaps") ?? [] {
            guard let number = Int(url.lastPathComponent.prefix(4)),
                  let map = try? BeatMap.decode(from: Data(contentsOf: url)) else { continue }
            beatMaps[number] = map
        }
    }

    #if DEBUG
    /// For screenshot mode: a library of just these hymns.
    init(hymns: [Hymn], beatMaps: [Int: BeatMap]) {
        self.hymns = hymns
        self.beatMaps = beatMaps
    }
    #endif

    func hymn(number: Int) -> Hymn? {
        hymns.first { $0.number == number }
    }

    /// Matches a hymn number prefix ("2", "20") or words in the title.
    func search(_ query: String) -> [Hymn] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return hymns }
        if q.allSatisfy(\.isNumber) {
            return hymns.filter { String($0.number).hasPrefix(q) }
        }
        return hymns.filter {
            $0.title.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}

extension Hymn {
    /// Verse numbers in singing order.
    var verseNumbers: [Int] {
        var seen = Set<Int>()
        return form.compactMap(\.verse).filter { seen.insert($0).inserted }
    }
}
