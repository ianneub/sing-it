import SingItCore
import SwiftUI

/// Choose part, verse and strictness, then start singing.
struct HymnSetupView: View {
    let hymn: Hymn
    @Environment(HymnLibrary.self) private var library
    @Environment(VoiceProfile.self) private var voice

    /// "auto" or a Part raw value.
    @AppStorage("part") private var partChoice = "auto"
    @AppStorage("tolerance") private var tolerance = 50.0
    @AppStorage("voiceProcessing") private var voiceProcessing = false
    /// "any", or the octave to sing in relative to written: "0", "-1", "-2", "1".
    @AppStorage("octave") private var octaveChoice = "any"
    /// With an octave chosen: whether other octaves count as misses (off: they count, and
    /// slips are pointed out).
    @AppStorage("strictOctave") private var strictOctave = false
    /// "organ", "alone" or "app" (the app plays the accompaniment).
    @AppStorage("singingWith") private var singingWith = "organ"
    /// Practice mode: MusicMix raw value.
    @AppStorage("musicMix") private var musicMix = MusicMix.full.rawValue
    @State private var verse = 1
    @State private var singing = false

    private var part: Part? { Part(rawValue: partChoice) }
    /// Auto and Any part match every octave; a single line can be held to one.
    private var octaveApplies: Bool { part != nil && part != .anyPart }
    private var octaveShift: Int? { octaveApplies ? Int(octaveChoice) : nil }

    var body: some View {
        Form {
            Section {
                LabeledContent("Tempo", value: tempoText)
                LabeledContent("Time", value: timeText)
                LabeledContent("Verses", value: "\(hymn.verseNumbers.count)")
            }

            Section {
                if let range = voice.range {
                    LabeledContent("Your range", value: range.text)
                    ForEach(VoiceFit.options(for: hymn, range: range).prefix(3)) { fit in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(fit.label)
                                Text(detail(of: fit)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if part == fit.part && octaveShift == fit.octaveShift {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            } else {
                                Button("Use") {
                                    partChoice = fit.part.rawValue
                                    octaveChoice = String(fit.octaveShift)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                } else {
                    Text("Sing a hymn or check your range, and Sing It will suggest the part and octave that fit your voice.")
                        .font(.callout)
                }
                NavigationLink("Check my range") { RangeCheckView() }
            } header: {
                Text("Your voice")
            } footer: {
                if voice.range != nil {
                    Text("Range \(voice.rangeSource). The best fits for this hymn come first. Pick one and stay in "
                         + "its octave: Sing It tells you when you slip out of it.")
                }
            }

            Section {
                Picker("Part", selection: $partChoice) {
                    Text("Auto").tag("auto")
                    Text(Part.melody.displayName).tag(Part.melody.rawValue)
                    Text(Part.anyPart.displayName).tag(Part.anyPart.rawValue)
                    Divider()
                    ForEach(Part.voices) { Text($0.displayName).tag($0.rawValue) }
                }
            } header: {
                Text("Your part")
            } footer: {
                Text(partFooter)
            }

            Section {
                Picker("Verse", selection: $verse) {
                    ForEach(hymn.verseNumbers, id: \.self) { Text("Verse \($0)").tag($0) }
                }
                Picker("Singing with", selection: $singingWith) {
                    Text("Organ").tag("organ")
                    Text("On my own").tag("alone")
                    if beatMap != nil { Text("App music").tag("app") }
                }
                .pickerStyle(.segmented)
                if practice && octaveApplies {
                    Picker("Music", selection: $musicMix) {
                        Text("Accompaniment").tag(MusicMix.full.rawValue)
                        Text("+ My part").tag(MusicMix.withPart.rawValue)
                        Text("My part only").tag(MusicMix.partOnly.rawValue)
                    }
                    .pickerStyle(.segmented)
                }
            } header: {
                Text("Start at")
            } footer: {
                Text(singingWithFooter)
            }

            Section {
                Picker("Scoring", selection: $tolerance) {
                    Text("Easy").tag(75.0)
                    Text("Normal").tag(50.0)
                    Text("Strict").tag(25.0)
                }
                .pickerStyle(.segmented)
                if octaveApplies {
                    Picker("Octave", selection: $octaveChoice) {
                        Text("Any octave").tag("any")
                        Text("As written").tag("0")
                        Text("1 octave down").tag("-1")
                        Text("2 octaves down").tag("-2")
                        Text("1 octave up").tag("1")
                    }
                    if octaveShift != nil {
                        Toggle("Other octaves count as misses", isOn: $strictOctave)
                    }
                }
                Toggle("Voice processing", isOn: $voiceProcessing)
            } header: {
                Text("Settings")
            } footer: {
                Text("In tune means within \(Int(tolerance)) cents of the note (100 cents = a half step). "
                     + octaveFooter
                     + "Voice processing helps the phone's own mic in a noisy room; with a headset mic, leave it off.")
            }

            Section {
                Button {
                    singing = true
                } label: {
                    Label("Start singing", systemImage: "mic.fill")
                        .frame(maxWidth: .infinity)
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .listRowInsets(EdgeInsets())
            } footer: {
                Text("Tip: a headset or earbud mic hears your voice much better than the congregation and organ. "
                     + "Start when the introduction ends; Sing It waits for your first note.")
            }
        }
        .navigationTitle("\(hymn.number). \(hymn.title)")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $singing) {
            SingView(hymn: hymn, part: part, verse: verse, tolerance: tolerance,
                     anyOctave: octaveShift == nil || !strictOctave,
                     octaveShift: octaveShift ?? 0, coachOctave: octaveShift != nil, steadyTempo: singingWith != "alone",
                     beatMap: practice ? beatMap : nil, voiceProcessing: voiceProcessing,
                     musicMix: MusicMix(rawValue: musicMix) ?? .full)
        }
    }

    private var octaveFooter: String {
        guard octaveApplies else { return "The right note counts in any octave. " }
        switch octaveShift {
        case nil: return "The right note counts in any octave, and the summary shows where you switched. "
        case let shift?:
            let aim = shift == 0 ? "the part as written"
                : "the part \(abs(shift) == 1 ? "an octave" : "\(abs(shift)) octaves") \(shift < 0 ? "down" : "up")"
            return "Aim for \(aim). Sing It points out when you slip into another octave"
                + (strictOctave ? " and counts it as a miss. " : ", but the right note still counts. ")
        }
    }

    private func detail(of fit: VoiceFit) -> String {
        var text = "\(Int((fit.inRange * 100).rounded()))% in your range"
        if fit.notesTooHigh > 0 { text += ", \(fit.notesTooHigh) notes too high (up to \(NoteName.name(fit.highest)))" }
        if fit.notesTooLow > 0 { text += ", \(fit.notesTooLow) too low (down to \(NoteName.name(fit.lowest)))" }
        return text
    }

    private var timeText: String {
        let base = "\(hymn.time.beats)/\(hymn.time.beatType)"
        return (hymn.timeChanges?.count ?? 0) > 1 ? base + " (changes)" : base
    }

    private var tempoText: String {
        guard let tempo = hymn.tempo else { return "—" }
        let unit = tempo.dotted == true ? "♩." : "♩"
        return "\(unit) = \(tempo.min)–\(tempo.max)"
    }

    private var beatMap: BeatMap? { library.beatMaps[hymn.number] }
    private var practice: Bool { singingWith == "app" && beatMap != nil }

    private var singingWithFooter: String {
        if practice {
            let download = AccompanimentStore.isDownloaded(hymn) ? "" : " (downloaded the first time, about 8 MB)"
            let mix: String
            switch octaveApplies ? MusicMix(rawValue: musicMix) ?? .full : .full {
            case .full: mix = ""
            case .withPart: mix = "Your line plays on top of it, in the octave you sing, so you hear exactly what to sing. "
            case .partOnly: mix = "After the introduction (or a short lead-in) you hear only your line, in the octave you sing. "
            }
            return "Sing It plays the accompaniment\(download) and always knows where you are. " + mix
                + "Wear AirPods or headphones to hear it; the phone's mic listens to you."
        }
        return singingWith == "alone"
            ? "Sing It follows your own timing, speeding up and slowing down with you."
            : "Sing It expects a steady tempo, as when an organ keeps time."
    }

    private var partFooter: String {
        switch part {
        case nil:
            return "Sing a line or two and Sing It works out which of the four parts you're on."
        case .melody:
            return "The tune everyone knows (the soprano line). Men usually sing it an octave down. "
                + "Written range \(rangeText(for: .melody))."
        case .anyPart:
            return "Every note of the chord counts: melody, alto, tenor or bass, and you can move between them. "
                + "Only notes outside the chord count against you."
        case let voice?:
            return "Range \(rangeText(for: voice))."
        }
    }

    private func rangeText(for part: Part) -> String {
        let range = Performance(hymn: hymn, part: part).pitchRange
        return "\(NoteName.name(range.lowerBound)) to \(NoteName.name(range.upperBound))"
    }
}
