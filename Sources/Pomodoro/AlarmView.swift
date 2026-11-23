import Combine
import SwiftUI

/// Rings repeatedly while `timer.alarmRinging` is true (end of a break during a committed cycle)
/// and shows a card that stays until the user starts the next session or ends the commitment.
@MainActor
final class AlarmController {
    /// Ring every few seconds at first, then back off so it isn't relentless if you're out of the room.
    private static let urgentInterval: TimeInterval = 3
    private static let urgentPeriod: TimeInterval = 120
    private static let relaxedInterval: TimeInterval = 15

    private let cards: CardPresenter
    private let timer: PomodoroTimer
    private let settings: AppSettings
    private var ringTimer: Timer?
    private var startedAt: Date?
    private var subscription: AnyCancellable?

    init(widget: FloatingWidgetController, timer: PomodoroTimer, settings: AppSettings) {
        self.cards = CardPresenter(widget: widget)
        self.timer = timer
        self.settings = settings
        subscription = timer.$alarmRinging
            .removeDuplicates()
            .sink { [weak self] ringing in
                MainActor.assumeIsolated { ringing ? self?.startRinging() : self?.stopRinging() }
            }
    }

    private var soundName: String {
        settings.soundName == SoundPlayer.none ? "Glass" : settings.soundName
    }

    private func startRinging() {
        startedAt = Date()
        cards.show(AlarmView(timer: timer, settings: settings))
        // The normal end-of-break sound has just played; the first repeat follows shortly after.
        scheduleNextRing()
    }

    private func stopRinging() {
        ringTimer?.invalidate()
        ringTimer = nil
        startedAt = nil
        cards.dismiss()
    }

    private func scheduleNextRing() {
        guard let startedAt else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        let interval = elapsed < Self.urgentPeriod ? Self.urgentInterval : Self.relaxedInterval
        let t = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.startedAt != nil else { return }
                SoundPlayer.play(self.soundName)
                self.scheduleNextRing()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        ringTimer = t
    }
}

struct AlarmView: View {
    @ObservedObject var timer: PomodoroTimer
    @ObservedObject var settings: AppSettings
    @State private var pulse = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14)
        let next = min(timer.completedInCycle + 1, settings.sessionsBeforeLongBreak)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Text("⏰")
                    .font(.system(size: 26))
                    .rotationEffect(.degrees(pulse ? 12 : -12))
                    .animation(.easeInOut(duration: 0.15).repeatForever(autoreverses: true), value: pulse)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Break's over").font(.headline)
                    Text("You committed to a full cycle. Session \(next) of \(settings.sessionsBeforeLongBreak) is up, \(timer.sessionsLeftInCycle) to go.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Button {
                    timer.start()
                } label: {
                    Label("Start Focus", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(Phase.focus.color)

                Spacer(minLength: 0)

                Button("End full cycle") { timer.endCommitment() }
                    .buttonStyle(.borderless)
                    .help("Something came up? Stop the alarm and drop the commitment for this cycle.")
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 300)
        .background(VisualEffectBackground(cornerRadius: 14))
        .overlay(shape.strokeBorder(Phase.focus.color.opacity(0.6), lineWidth: 1.5))
        .clipShape(shape)
        .onAppear { pulse = true }
    }
}
