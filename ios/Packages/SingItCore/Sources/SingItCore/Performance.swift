import Foundation

/// One part of a hymn laid out in the order it is sung: every pass through the `form`
/// (verse 1, chorus, verse 2, ...) one after another. Times are quarter-note beats from
/// the start of the performance, not of the printed score.
///
/// `.melody` is the soprano line. `.anyPart` merges all four voices: the timeline is cut
/// wherever any voice changes note, and each piece accepts every pitch sounding then.
public struct Performance: Sendable {
    public let hymn: Hymn
    public let part: Part
    public let passes: [Pass]
    public let notes: [PerformedNote]
    public let syllables: [PerformedSyllable]
    /// Lyrics grouped as printed: one line per system of music, per pass.
    public let lines: [LyricDisplayLine]
    public let totalBeats: Double
    /// Octaves the notes are moved from where they're written (-1: sung an octave down).
    public let octaveShift: Int

    public struct Pass: Sendable {
        public let index: Int
        public let sectionIndex: Int
        public let kind: String
        public let verse: Int?
        public let start: Double
        public let end: Double
    }

    private init(hymn: Hymn, part: Part, passes: [Pass], notes: [PerformedNote], syllables: [PerformedSyllable],
                 lines: [LyricDisplayLine], totalBeats: Double) {
        self.hymn = hymn
        self.part = part
        self.passes = passes
        self.notes = notes
        self.syllables = syllables
        self.lines = lines
        self.totalBeats = totalBeats
        self.octaveShift = 0
    }

    /// `octaveShift` moves the part by whole octaves: -1 for a man singing the melody an
    /// octave down. Ignored for `.anyPart`.
    public init(hymn: Hymn, part: Part, octaveShift: Int = 0) {
        if part == .anyPart {
            self = Performance.anyPart(hymn)
            return
        }
        self.hymn = hymn
        self.part = part
        self.octaveShift = octaveShift
        let shift = 12 * octaveShift
        let sourceNotes = hymn.notes(for: part.sourceVoice)
        let systemStarts = Performance.systemStarts(hymn)

        var passes: [Pass] = []
        var notes: [PerformedNote] = []
        var syllables: [PerformedSyllable] = []
        var lines: [LyricDisplayLine] = []
        var t = 0.0

        for (index, entry) in hymn.form.enumerated() {
            let section = hymn.sections[entry.section]
            let offset = t - section.start
            passes.append(Pass(index: index, sectionIndex: entry.section, kind: section.kind,
                               verse: entry.verse, start: t, end: t + section.end - section.start))

            // Notes: clip to the section so a tie across its boundary still fills the pass.
            for note in sourceNotes where note.start < section.end && note.start + note.duration > section.start {
                let start = max(note.start, section.start)
                let end = min(note.start + note.duration, section.end)
                let sungThisVerse = note.verses.map { verses in entry.verse.map(verses.contains) ?? true } ?? true
                let midi = sungThisVerse ? note.midi : nil
                notes.append(PerformedNote(
                    start: start + offset, duration: end - start, midi: note.isRest ? nil : midi.map { $0 + shift },
                    alternates: (note.alt ?? []).map { $0.midi + shift }, fermata: note.fermata == true,
                    measure: note.measure, passIndex: index, sourceStart: start))
            }

            // Lyrics: this verse's line, with any echo line for this part spliced in.
            let passSyllables = Performance.lyrics(for: section, verse: entry.verse, part: part)
            let firstSyllable = syllables.count
            for s in passSyllables {
                syllables.append(PerformedSyllable(start: s.start + offset, text: s.text, syllabic: s.syllabic,
                                                   passIndex: index))
            }

            // Display lines break where printed systems start.
            let cuts = [section.start] + systemStarts.filter { $0 > section.start && $0 < section.end } + [section.end]
            for (a, b) in zip(cuts, cuts.dropFirst()) where b > a {
                let range = syllables[firstSyllable...].indices.filter {
                    syllables[$0].start >= a + offset - 1e-9 && syllables[$0].start < b + offset - 1e-9
                }
                if let first = range.first, let last = range.last {
                    lines.append(LyricDisplayLine(passIndex: index, start: a + offset, end: b + offset,
                                                  syllables: first..<(last + 1)))
                }
            }
            t += section.end - section.start
        }

        self.passes = passes
        self.notes = notes.sorted { $0.start < $1.start }
        self.syllables = syllables
        self.lines = lines
        self.totalBeats = t
    }

    /// All four voices merged: each piece of the timeline accepts every pitch sounding then,
    /// melody first. Lyrics are the melody's.
    static func anyPart(_ hymn: Hymn) -> Performance {
        let voices = Part.voices.map { Performance(hymn: hymn, part: $0) }
        let melody = voices[0]
        var cuts = Set<Double>()
        for voice in voices {
            for note in voice.notes {
                cuts.insert(note.start)
                cuts.insert(note.end)
            }
        }
        let sorted = cuts.sorted()
        var notes: [PerformedNote] = []
        for (a, b) in zip(sorted, sorted.dropFirst()) where b - a > 1e-9 {
            var targets: [Int] = [], parts: [String] = []
            var fermata = false
            for (part, voice) in zip(Part.voices, voices) {
                guard let i = voice.noteIndex(at: a + 1e-9) else { continue }
                let note = voice.notes[i]
                fermata = fermata || note.fermata
                for m in note.targets where !targets.contains(m) {
                    targets.append(m)
                    parts.append(part.rawValue)
                }
            }
            let tune = melody.noteIndex(at: a + 1e-9).map { melody.notes[$0] }
            notes.append(PerformedNote(
                start: a, duration: b - a, midi: targets.first, alternates: Array(targets.dropFirst()),
                fermata: fermata, measure: tune?.measure ?? 0, passIndex: tune?.passIndex ?? 0,
                sourceStart: (tune?.sourceStart ?? 0) + (a - (tune?.start ?? a)), targetParts: parts))
        }
        return Performance(hymn: hymn, part: .anyPart, passes: melody.passes, notes: notes,
                           syllables: melody.syllables, lines: melody.lines, totalBeats: melody.totalBeats)
    }

    /// Start beats (in the printed score) of each system after the first.
    static func systemStarts(_ hymn: Hymn) -> [Double] {
        var first: [Int: Double] = [:]
        for notes in hymn.parts.values {
            for note in notes {
                guard let system = note.heads.first?.system else { continue }
                first[system] = min(first[system] ?? .infinity, note.start)
            }
        }
        return first.keys.sorted().dropFirst().compactMap { first[$0] }
    }

    static func lyrics(for section: Hymn.Section, verse: Int?, part: Part) -> [Hymn.Syllable] {
        let main = section.lyrics.filter { $0.parts == nil }
        let line = main.first { $0.verse == verse && verse != nil } ?? main.first { $0.verse == nil } ?? main.first
        var result = line?.syllables ?? []
        for echo in section.lyrics where echo.parts?.contains(part.rawValue) == true {
            let start = echo.start ?? section.start, end = echo.end ?? section.end
            result.removeAll { $0.start >= start && $0.start < end }
            result += echo.syllables
        }
        return result.sorted { $0.start < $1.start }
    }

    /// Index of the note sounding at `beat`, or nil past the end.
    public func noteIndex(at beat: Double) -> Int? {
        var lo = 0, hi = notes.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if notes[mid].end <= beat { lo = mid + 1 } else if notes[mid].start > beat { hi = mid - 1 } else { return mid }
        }
        return nil
    }

    /// Index of the last syllable started at or before `beat`.
    public func syllableIndex(at beat: Double) -> Int? {
        syllables.lastIndex { $0.start <= beat + 1e-9 }
    }

    public func lineIndex(at beat: Double) -> Int? {
        lines.lastIndex { $0.start <= beat + 1e-9 }
    }

    public func pass(at beat: Double) -> Pass? {
        passes.last { $0.start <= beat + 1e-9 }
    }

    /// Lowest and highest MIDI note this part sings (including alternatives).
    public var pitchRange: ClosedRange<Int> {
        let all = notes.flatMap { note in note.midi.map { [$0] + note.alternates } ?? [] }
        guard let lo = all.min(), let hi = all.max() else { return 60...72 }
        return lo...hi
    }

    /// Beat at which a verse's first pass starts.
    public func start(ofVerse verse: Int) -> Double {
        passes.first { $0.verse == verse }?.start ?? 0
    }
}

public struct PerformedNote: Sendable, Equatable {
    public let start: Double
    public let duration: Double
    /// nil for a rest.
    public let midi: Int?
    /// Also-correct pitches, e.g. an optional low octave.
    public let alternates: [Int]
    public let fermata: Bool
    public let measure: Int
    public let passIndex: Int
    /// Start in the printed score, for pointing back at the page.
    public let sourceStart: Double
    /// For `.anyPart`: which voice each of `targets` belongs to (soprano, alto, ...).
    public var targetParts: [String] = []

    public var end: Double { start + duration }
    public var isRest: Bool { midi == nil }
    public var targets: [Int] { midi.map { [$0] + alternates } ?? [] }
}

public struct PerformedSyllable: Sendable {
    public let start: Double
    public let text: String
    public let syllabic: String
    public let passIndex: Int

    /// The syllable followed by a hyphen when the word continues.
    public var displayText: String { syllabic == "begin" || syllabic == "middle" ? text + "-" : text }
}

public struct LyricDisplayLine: Sendable {
    public let passIndex: Int
    public let start: Double
    public let end: Double
    public let syllables: Range<Int>
}

public enum NoteName {
    static let names = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]

    /// "B♭3" style name for a MIDI note number.
    public static func name(_ midi: Int) -> String {
        names[((midi % 12) + 12) % 12] + String(midi / 12 - 1)
    }
}
