import SingItCore
import SwiftUI

/// Results after singing a hymn.
struct SummaryView: View {
    let summary: SessionSummary
    /// Offered for mistakes repeated across verses, when the line can be practised with music.
    var practise: ((SessionSummary.RecurringSpot) -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 4) {
                        Text("\(Int(summary.score.rounded()))%")
                            .font(.system(size: 56, weight: .bold, design: .rounded))
                        Text("\(summary.inTuneNotes) of \(summary.scoredNotes) notes in tune")
                            .foregroundStyle(.secondary)
                        if summary.bestStreak >= 3 {
                            Label("Best streak: \(summary.bestStreak) notes", systemImage: "flame.fill")
                                .foregroundStyle(.orange)
                                .padding(.top, 4)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }

                if summary.scoredNotes > 0 {
                    Section("Tendency") {
                        Text(tendencyText)
                    }
                }

                if let spots = summary.recurring, !spots.isEmpty {
                    Section {
                        ForEach(spots) { spot in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(recurringTitle(spot)).font(.headline)
                                Text(recurringDetail(spot)).font(.subheadline).foregroundStyle(.secondary)
                                if let practise {
                                    Button {
                                        practise(spot)
                                    } label: {
                                        Label("Practise “\(spot.lineText)”", systemImage: "repeat")
                                            .font(.subheadline)
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    } header: {
                        Text("Same spot, every verse")
                    } footer: {
                        Text("Notes you missed in more than one verse: habits worth drilling.")
                    }
                }

                if let octaves = summary.octaves, !octaves.isEmpty, summary.part != Part.anyPart.rawValue {
                    Section {
                        ForEach(octaves, id: \.octave) { share in
                            LabeledContent(octaveName(share.octave) + (share.octave == summary.octaveShift ? " (your choice)" : ""),
                                           value: "\(Int((share.share * 100).rounded()))%")
                        }
                        if let changes = summary.octaveChangeCount, changes > 0 {
                            Text(octaveChangeText(changes))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Octaves you sang in")
                    }
                }

                if let lag = summary.musicLag, abs(lag) >= 0.05 {
                    Section {
                        Text("You sang about \(String(format: "%.1f", abs(lag))) seconds \(lag > 0 ? "behind" : "ahead of") "
                             + "the music. That's normal, and Sing It allowed for it when scoring.")
                            .font(.subheadline)
                    } header: {
                        Text("Timing")
                    }
                }

                if let shares = summary.partShares, !shares.isEmpty {
                    Section("Parts you sang") {
                        ForEach(shares.sorted { $0.value > $1.value }, id: \.key) { part, share in
                            LabeledContent(partName(part), value: "\(Int((share * 100).rounded()))%")
                        }
                    }
                }

                if !summary.passes.isEmpty {
                    Section("By verse") {
                        ForEach(Array(summary.passes.enumerated()), id: \.offset) { _, pass in
                            LabeledContent(pass.verse.map { "Verse \($0)" } ?? pass.kind.capitalized,
                                           value: "\(Int(pass.score.rounded()))%")
                        }
                    }
                }

                if !summary.troubleSpots.isEmpty {
                    Section("Practice these") {
                        ForEach(Array(summary.troubleSpots.enumerated()), id: \.offset) { _, spot in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(title(of: spot))
                                    .font(.headline)
                                Text(detail(of: spot))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("\(summary.hymnNumber). \(summary.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func recurringTitle(_ spot: SessionSummary.RecurringSpot) -> String {
        let words = Array(Set(spot.lyrics)).sorted().prefix(3).map { "“\($0)”" }.joined(separator: ", ")
        return "\(words) · \(spot.kind.capitalized) · \(spot.pitch)"
    }

    private func recurringDetail(_ spot: SessionSummary.RecurringSpot) -> String {
        if let octave = spot.wrongOctave {
            return "Missed \(spot.timesMissed) of \(spot.timesSung) times: the right note, but \(octaveName(octave).lowercased())."
        }
        if let spread = spot.meanAbsCents, abs(spot.meanCents) < 0.4 * spread {
            return "Missed \(spot.timesMissed) of \(spot.timesSung) times, wandering around the note "
                + String(format: "(about ±%.1f half steps). Try holding it steady.", spread / 100)
        }
        let halfSteps = abs(spot.meanCents) / 100
        let direction = spot.meanCents < 0 ? "low" : "high"
        let amount = halfSteps < 0.75 ? "a little \(direction)" : String(format: "about %.0f half step%@ %@", halfSteps.rounded(),
                                                                         halfSteps.rounded() == 1 ? "" : "s", direction)
        return "Missed \(spot.timesMissed) of \(spot.timesSung) times, \(amount)."
    }

    private func octaveName(_ octave: Int) -> String {
        switch octave {
        case 0: return "As written"
        case -1: return "1 octave down"
        case 1: return "1 octave up"
        default: return "\(abs(octave)) octaves \(octave < 0 ? "down" : "up")"
        }
    }

    private func octaveChangeText(_ count: Int) -> String {
        var text = "You changed octave \(count) time\(count == 1 ? "" : "s")"
        let places = (summary.octaveChanges ?? []).prefix(4).map { change -> String in
            let place = change.verse.map { "verse \($0)" } ?? change.kind
            let word = change.lyric.map { " at “\($0)”" } ?? ""
            return "\(change.to < change.from ? "down" : "up") in \(place)\(word)"
        }
        if !places.isEmpty { text += ": " + places.joined(separator: "; ") }
        return text + "."
    }

    /// Voice names as a singer thinks of them: the soprano line is the melody.
    private func partName(_ raw: String) -> String {
        raw == Part.soprano.rawValue ? "Melody" : Part(rawValue: raw)?.displayName ?? raw.capitalized
    }

    private var tendencyText: String {
        let cents = summary.tendencyCents
        if abs(cents) < 10 { return "Nicely centred: on average within \(Int(abs(cents).rounded())) cents." }
        return "On average you were \(Int(abs(cents).rounded())) cents \(cents < 0 ? "flat (a little low)" : "sharp (a little high)")."
    }

    private func title(of spot: SessionSummary.TroubleSpot) -> String {
        guard let lyric = spot.lyric else { return spot.pitch }
        return "“\(lyric)” · \(spot.pitch)"
    }

    private func detail(of spot: SessionSummary.TroubleSpot) -> String {
        let place = spot.verse.map { "Verse \($0), measure \(spot.measure)" } ?? "Measure \(spot.measure)"
        let accuracy = Int((spot.accuracy * 100).rounded())
        return "\(place) · \(accuracy)% in tune, \(centsText(spot.meanCents))"
    }

    private func centsText(_ cents: Double) -> String {
        let c = Int(abs(cents).rounded())
        return c < 10 ? "centred" : "\(c)¢ \(cents < 0 ? "flat" : "sharp")"
    }
}
