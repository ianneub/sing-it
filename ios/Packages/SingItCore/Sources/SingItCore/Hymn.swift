import Foundation

/// A hymn as produced by `tools/hymnpdf` (see CLAUDE.md, "Hymn data pipeline").
/// Times are in quarter-note beats from the start of the written score.
public struct Hymn: Decodable, Identifiable, Sendable {
    public let number: Int
    public let title: String
    public let expression: String?
    public let tempo: Tempo?
    public let key: Key
    public let time: TimeSignature
    public let timeChanges: [TimeChange]?
    public let credits: [String]
    public let measures: [Measure]
    public let sections: [Section]
    public let form: [FormEntry]
    public let intro: [BeatRange]
    public let parts: [String: [Note]]
    public let voicing: [VoicingChange]?

    public var id: Int { number }

    public static func decode(from data: Data) throws -> Hymn {
        try JSONDecoder().decode(Hymn.self, from: data)
    }

    public func notes(for part: Part) -> [Note] { parts[part.sourceVoice.rawValue] ?? [] }

    /// Quarter-note beats per minute. A dotted tempo (6/8 hymns) counts dotted quarters.
    public var quarterBPMRange: ClosedRange<Double> {
        guard let tempo else { return 90...90 }
        let scale = tempo.dotted == true ? 1.5 : 1.0
        return Double(tempo.min) * scale...Double(max(tempo.min, tempo.max)) * scale
    }

    public struct Tempo: Decodable, Sendable {
        public let beatUnit: String
        public let min: Int
        public let max: Int
        public let dotted: Bool?
    }

    public struct Key: Decodable, Sendable {
        public let fifths: Int
        public let mode: String?
    }

    public struct TimeSignature: Decodable, Sendable {
        public let beats: Int
        public let beatType: Int
    }

    public struct TimeChange: Decodable, Sendable {
        public let start: Double
        public let beats: Int
        public let beatType: Int
    }

    public struct Measure: Decodable, Sendable {
        public let number: Int
        public let start: Double
        public let duration: Double
    }

    public struct BeatRange: Decodable, Sendable {
        public let start: Double
        public let end: Double
    }

    public struct VoicingChange: Decodable, Sendable {
        public let start: Double
        public let voicing: String
    }

    public struct Section: Decodable, Sendable {
        public let kind: String
        public let start: Double
        public let end: Double
        public let lyrics: [LyricLine]
    }

    public struct LyricLine: Decodable, Sendable {
        public let verse: Int?
        public let syllables: [Syllable]
        /// Set on a line sung by only some parts (a men's echo); it replaces the main
        /// line for those parts between `start` and `end`.
        public let parts: [String]?
        public let start: Double?
        public let end: Double?
        public let approximate: Bool?
    }

    public struct Syllable: Decodable, Sendable {
        public let start: Double
        public let text: String
        /// "single", "begin", "middle" or "end" (MusicXML's convention).
        public let syllabic: String
    }

    public struct FormEntry: Decodable, Sendable {
        public let section: Int
        public let verse: Int?
    }

    public struct Note: Decodable, Sendable {
        public let start: Double
        public let duration: Double
        public let midi: Int?
        public let pitch: String?
        public let measure: Int
        public let rest: Bool?
        public let fermata: Bool?
        /// Optional alternative pitches (e.g. a low octave for basses).
        public let alt: [Alternative]?
        /// When present, only these verses sing the note; other verses rest.
        public let verses: [Int]?
        public let heads: [Head]

        public var isRest: Bool { rest == true || midi == nil }

        public struct Alternative: Decodable, Sendable {
            public let midi: Int
            public let pitch: String
        }

        /// Where the notehead is printed: PDF points, y down.
        public struct Head: Decodable, Sendable {
            public let page: Int
            public let system: Int
            public let x: Double
            public let y: Double
        }
    }
}

/// What the singer is singing: one of the four printed voices, the melody (the soprano
/// line, sung in any octave), or any part (every note of the chord counts).
public enum Part: String, CaseIterable, Identifiable, Sendable {
    case soprano, alto, tenor, bass, melody, anyPart

    /// The four printed voices.
    public static let voices: [Part] = [.soprano, .alto, .tenor, .bass]

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .melody: "Melody"
        case .anyPart: "Any part"
        default: rawValue.capitalized
        }
    }

    /// The printed voice whose notes this follows (melody is the soprano line).
    public var sourceVoice: Part { self == .melody ? .soprano : self }
}
