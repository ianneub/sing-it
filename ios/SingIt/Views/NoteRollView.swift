import SingItCore
import SwiftUI

/// Scrolling "piano roll": the part's notes as bars at their pitch, a playhead at the
/// singer's position, and the sung pitch drawn as a trail of dots.
struct NoteRollView: View {
    let controller: SingController

    var body: some View {
        // Redrawn every screen frame while listening, at the music's position right then:
        // updating only when the controller refreshes made the roll stutter.
        TimelineView(.animation(paused: !controller.isListening)) { _ in
            roll(at: controller.displayPosition(), singer: controller.displayPosition(lag: controller.session.musicLag))
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel("Notes for your part, with your singing drawn as dots")
    }

    /// The roll with the playhead at `position` (the music) and the current pitch at
    /// `singer` (where the singer is, a little behind).
    private func roll(at position: Double, singer: Double) -> some View {
        let live = controller.live
        let performance = controller.performance
        let from = position - controller.lookBehind
        let to = position + controller.lookAhead
        let range = performance.pitchRange
        let lo = Double(range.lowerBound - 2), hi = Double(range.upperBound + 2)

        return Canvas { context, size in
            let x: (Double) -> CGFloat = { beat in CGFloat((beat - from) / (to - from)) * size.width }
            let y: (Double) -> CGFloat = { midi in size.height * CGFloat(1 - (midi - lo) / (hi - lo)) }
            let row: CGFloat = size.height / CGFloat(hi - lo)

            // Pitch guide lines, labelled at each pitch the part sings.
            let sung = Set(performance.notes.flatMap(\.targets))
            for m in Int(lo)...Int(hi) {
                let yy = y(Double(m))
                var line = Path()
                line.move(to: CGPoint(x: 0, y: yy))
                line.addLine(to: CGPoint(x: size.width, y: yy))
                let isC = m % 12 == 0
                context.stroke(line, with: .color(.secondary.opacity(isC ? 0.35 : 0.12)), lineWidth: isC ? 1 : 0.5)
                if sung.contains(m) {
                    context.draw(Text(NoteName.name(m)).font(.system(size: 9)).foregroundStyle(.secondary),
                                 at: CGPoint(x: 2, y: yy), anchor: .leading)
                }
            }

            // Target notes. With any part, every voice's note is a real target: the melody is
            // drawn strongest and the others as lighter bars. Otherwise alternatives (an
            // optional low octave) are drawn hollow.
            let chord = performance.part == .anyPart
            let gap: CGFloat = chord ? 0 : 2  // chord pieces are cut wherever any voice moves
            let visible = performance.notes.indices.filter { performance.notes[$0].end > from && performance.notes[$0].start < to }
            for i in visible {
                let note = performance.notes[i]
                guard let midi = note.midi else { continue }
                let rect = CGRect(x: x(note.start) + gap / 2, y: y(Double(midi)) - row * 0.4,
                                  width: max(2, x(note.end) - x(note.start) - gap), height: row * 0.8)
                let current = live.noteIndex == i
                let fill = color(for: i, current: current)
                for alt in note.alternates {
                    let altRect = rect.offsetBy(dx: 0, dy: y(Double(alt)) - y(Double(midi)))
                    if chord {
                        context.fill(Path(roundedRect: altRect, cornerRadius: 3), with: .color(fill.opacity(0.45)))
                    } else {
                        context.stroke(Path(roundedRect: altRect, cornerRadius: 3), with: .color(.secondary), lineWidth: 1)
                    }
                }
                context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(fill))
                if current && !chord {
                    context.stroke(Path(roundedRect: rect, cornerRadius: 3), with: .color(.primary), lineWidth: 1.5)
                }
                if note.fermata {
                    context.draw(Text("𝄐").font(.caption), at: CGPoint(x: rect.midX, y: rect.minY - 8))
                }
            }

            // Syllables along the bottom.
            for s in performance.syllables where s.start >= from && s.start < to {
                context.draw(Text(s.displayText).font(.caption2).foregroundStyle(.secondary),
                             at: CGPoint(x: x(s.start) + 2, y: size.height - 8), anchor: .leading)
            }

            // What was sung.
            for p in controller.trace where p.beat >= from {
                let point = CGPoint(x: x(p.beat), y: y(min(max(p.midi, lo), hi)))
                let color: Color = p.inTune.map { $0 ? (p.slipped ? .yellow : .green) : .orange } ?? .gray
                context.fill(Path(ellipseIn: CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)),
                             with: .color(color))
            }

            // Playhead (the music) and the current pitch (where the singer is).
            let headX = x(position)
            var head = Path()
            head.move(to: CGPoint(x: headX, y: 0))
            head.addLine(to: CGPoint(x: headX, y: size.height))
            context.stroke(head, with: .color(.accentColor.opacity(0.6)), lineWidth: 2)
            if let midi = live.sungMidiNearTarget, live.started {
                let point = CGPoint(x: x(singer), y: y(min(max(midi, lo), hi)))
                let session = controller.session
                let inTune = live.comparison.map { (session.anyOctave || !$0.octaveOff) && abs($0.cents) <= session.tolerance }
                context.fill(Path(ellipseIn: CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14)),
                             with: .color(inTune == true ? .green : .orange))
            }
        }
    }

    /// Sung notes turn green/yellow/red by accuracy; upcoming notes are blue.
    private func color(for index: Int, current: Bool) -> Color {
        if let r = controller.results[index], r.frames >= 5 {
            return r.accuracy >= 0.7 ? .green.opacity(0.7) : r.accuracy >= 0.4 ? .yellow.opacity(0.7) : .red.opacity(0.6)
        }
        return current ? .blue.opacity(0.7) : .blue.opacity(0.35)
    }
}
