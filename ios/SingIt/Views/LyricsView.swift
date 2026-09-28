import SingItCore
import SwiftUI

/// The current line of words with the current syllable highlighted, and the next line.
/// Tapping a line moves there (for when the app has lost your place).
struct LyricsView: View {
    let performance: Performance
    let position: Double
    let onTapLine: (Int) -> Void

    var body: some View {
        let current = performance.lineIndex(at: position) ?? 0
        let syllable = performance.syllableIndex(at: position)
        VStack(alignment: .leading, spacing: 6) {
            if performance.lines.indices.contains(current) {
                line(current, highlight: syllable)
                    .font(.title3)
            }
            if performance.lines.indices.contains(current + 1) {
                line(current + 1, highlight: nil)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
    }

    private func line(_ index: Int, highlight: Int?) -> some View {
        var text = AttributedString()
        for i in performance.lines[index].syllables {
            let s = performance.syllables[i]
            // Syllables of one word join up; words are separated by spaces.
            var piece = AttributedString(s.text + (s.syllabic == "begin" || s.syllabic == "middle" ? "" : " "))
            if i == highlight {
                piece.swiftUI.foregroundColor = .accentColor
                piece.inlinePresentationIntent = .stronglyEmphasized
            }
            text += piece
        }
        return Text(text)
            .lineLimit(2)
            .contentShape(Rectangle())
            .onTapGesture { onTapLine(index) }
    }
}
