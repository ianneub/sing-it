import SingItCore
import SwiftUI

/// The note to sing, how far off you are, and which way to go.
struct TuningMeterView: View {
    let live: LiveState
    let tolerance: Double

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(targetName)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .frame(minWidth: 70, alignment: .leading)
                Text(hintText)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(hintColor)
                Spacer()
                if let cents = live.meterCents, live.hint != .rest, live.hint != .waiting {
                    Text("\(cents >= 0 ? "+" : "")\(Int(cents.rounded()))¢")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            meter
                .frame(height: 22)
        }
    }

    private var meter: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let span = 100.0  // cents either side shown
            let zone = CGFloat(tolerance / span) * w / 2
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.tertiarySystemFill))
                Capsule().fill(.green.opacity(0.35))
                    .frame(width: zone * 2)
                    .offset(x: w / 2 - zone)
                Rectangle().fill(.secondary).frame(width: 1).offset(x: w / 2)
                if let cents = live.meterCents, live.started, live.hint != .rest {
                    let clamped = min(max(cents, -span), span)
                    // Only the dot glides; animating the whole view cross-faded the hint text.
                    Circle()
                        .fill(hintColor)
                        .frame(width: 18, height: 18)
                        .offset(x: w / 2 + CGFloat(clamped / span) * w / 2 - 9)
                        .animation(.easeOut(duration: 0.1), value: clamped)
                }
            }
            .overlay(alignment: .leading) { Text("♭").font(.caption).padding(.leading, 6).foregroundStyle(.secondary) }
            .overlay(alignment: .trailing) { Text("♯").font(.caption).padding(.trailing, 6).foregroundStyle(.secondary) }
        }
    }

    private var targetName: String {
        guard let target = live.comparison?.target else { return live.hint == .rest ? "𝄽" : "–" }
        return NoteName.name(target)
    }

    private var hintText: String {
        switch live.hint {
        case .waiting: "Waiting for you to sing"
        case .intro: "Introduction…"
        case .silent: "Listening…"
        case .rest: "Rest"
        case .higher: "Sing higher ↑"
        case .lower: "Sing lower ↓"
        case .onPitch: "On pitch ✓"
        case .octave: (live.comparison?.octaves ?? 0) < 0 ? "An octave low — come up ↑" : "An octave high — go down ↓"
        case .octaveSlip: (live.comparison?.octaves ?? 0) < 0 ? "Right note, an octave low ↑" : "Right note, an octave high ↓"
        }
    }

    private var hintColor: Color {
        switch live.hint {
        case .onPitch: .green
        case .higher, .lower, .octave: .orange
        case .octaveSlip: .yellow
        default: .secondary
        }
    }
}
