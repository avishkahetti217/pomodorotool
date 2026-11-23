import Combine
import SwiftUI

/// Shows the "welcome back" card whenever the timer reports the user has returned
/// from an auto-paused focus session, and hides it once they choose.
@MainActor
final class AwayController {
    private let cards: CardPresenter
    private let timer: PomodoroTimer
    private var subscription: AnyCancellable?

    init(widget: FloatingWidgetController, timer: PomodoroTimer) {
        self.cards = CardPresenter(widget: widget)
        self.timer = timer
        subscription = timer.$awayReport
            .removeDuplicates()
            .sink { [weak self] report in
                MainActor.assumeIsolated { self?.update(report) }
            }
    }

    private func update(_ report: AwayReport?) {
        guard let report else {
            cards.dismiss()
            return
        }
        cards.show(AwayView(report: report,
                            remaining: timer.remaining,
                            timeString: timer.timeString,
                            timer: timer))
    }
}

struct AwayView: View {
    let report: AwayReport
    let remaining: TimeInterval
    let timeString: String
    let timer: PomodoroTimer

    private var awayText: String {
        let minutes = max(1, Int((report.duration / 60).rounded()))
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    private var countFinishes: Bool { report.duration >= remaining }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Text("👋").font(.system(size: 26))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Welcome back").font(.headline)
                    Text("You were away for \(awayText). Your focus session is paused at \(timeString).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button { timer.dismissAway() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help("Keep it paused")
            }

            HStack(spacing: 8) {
                Button("Resume") { timer.resumeIgnoringAway() }
                    .buttonStyle(.borderedProminent)
                    .tint(Phase.focus.color)
                    .help("Continue from \(timeString); the time away isn't counted")
                Button(countFinishes ? "Count it & finish" : "Count time away") { timer.resumeCountingAway() }
                    .help("Treat the time away as focus, e.g. a whiteboard session or a work call")
                Spacer(minLength: 0)
                Button("Restart") { timer.reset() }
                    .buttonStyle(.borderless)
                    .help("Start this focus session over")
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 300)
        .background(VisualEffectBackground(cornerRadius: 14))
        .overlay(shape.strokeBorder(Color.primary.opacity(0.1)))
        .clipShape(shape)
    }
}
