import AppKit
import Combine
import Foundation

enum Phase: String {
    case focus, shortBreak, longBreak

    var title: String {
        switch self {
        case .focus: return "Focus"
        case .shortBreak: return "Short Break"
        case .longBreak: return "Long Break"
        }
    }

    var isBreak: Bool { self != .focus }

    var symbol: String {
        switch self {
        case .focus: return "timer"
        case .shortBreak: return "cup.and.saucer.fill"
        case .longBreak: return "figure.walk"
        }
    }
}

/// The Pomodoro state machine: focus → short break → … → long break after N focus sessions.
/// Time is tracked against an absolute end date, so it stays accurate across sleep and app-nap.
@MainActor
final class PomodoroTimer: ObservableObject {
    enum RunState { case idle, running, paused }

    @Published private(set) var phase: Phase = .focus
    @Published private(set) var state: RunState = .idle
    /// Focus sessions completed in the current cycle (resets after a long break).
    @Published private(set) var completedInCycle = 0
    @Published private var now = Date()
    @Published private var pausedRemaining: TimeInterval = 0
    /// A screen-free suggestion picked when a break begins; nil during focus.
    @Published private(set) var breakTip: String?

    /// Called after a focus session completes (used for the reward card).
    var onFocusCompleted: ((Celebration) -> Void)?

    private var endDate: Date?
    private var ticker: Timer?
    private var cancellables = Set<AnyCancellable>()

    private let settings: AppSettings
    private let stats: StatsStore
    private let notifier: Notifier
    private let blocker: AppBlocker

    init(settings: AppSettings, stats: StatsStore, notifier: Notifier, blocker: AppBlocker) {
        self.settings = settings
        self.stats = stats
        self.notifier = notifier
        self.blocker = blocker
        // Durations shown while idle come from settings, so redraw when they change.
        settings.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: - Derived values

    var totalDuration: TimeInterval { settings.duration(for: phase) }

    var remaining: TimeInterval {
        switch state {
        case .idle: return totalDuration
        case .paused: return pausedRemaining
        case .running: return max(0, (endDate ?? now).timeIntervalSince(now))
        }
    }

    var progress: Double {
        guard totalDuration > 0 else { return 0 }
        return (1 - remaining / totalDuration).clamped(0...1)
    }

    var timeString: String {
        let seconds = Int(remaining.rounded(.up))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    var primaryActionTitle: String {
        switch state {
        case .idle: return phase.isBreak ? "Start Break" : "Start Focus"
        case .running: return "Pause"
        case .paused: return "Resume"
        }
    }

    var sessionsLeftInCycle: Int {
        max(0, settings.sessionsBeforeLongBreak - completedInCycle)
    }

    /// The break idea to display, respecting the user's setting.
    var visibleBreakTip: String? {
        settings.showBreakTips && phase.isBreak ? breakTip : nil
    }

    var isBlockingActive: Bool {
        settings.blockingEnabled && state == .running && phase == .focus
    }

    // MARK: - Controls

    func toggle() {
        state == .running ? pause() : start()
    }

    func start() {
        guard state != .running else { return }
        let length = state == .paused ? pausedRemaining : totalDuration
        now = Date()
        endDate = now.addingTimeInterval(length)
        state = .running
        startTicker()
        syncBlocker()
    }

    func pause() {
        guard state == .running, let end = endDate else { return }
        pausedRemaining = max(0, end.timeIntervalSinceNow)
        endDate = nil
        state = .paused
        stopTicker()
        syncBlocker()
    }

    /// Restart the current phase from its full duration.
    func reset() {
        stopTicker()
        endDate = nil
        state = .idle
        syncBlocker()
    }

    /// Move to the next phase without counting the current one as completed.
    func skip() {
        stopTicker()
        endDate = nil
        advance(completed: false)
    }

    /// Back to the first focus session of a fresh cycle.
    func resetCycle() {
        reset()
        phase = .focus
        completedInCycle = 0
        breakTip = nil
    }

    // MARK: - Internals

    private func tick() {
        now = Date()
        if let end = endDate, now >= end {
            finish()
        }
    }

    private func finish() {
        stopTicker()
        endDate = nil
        let finished = phase
        if finished == .focus {
            stats.recordPomodoro(focusSeconds: totalDuration)
        }
        advance(completed: true)

        if finished == .focus || settings.soundAfterBreaks {
            SoundPlayer.play(settings.soundName)
        }
        let nextMinutes = settings.minutes(for: phase)
        let progress = finished == .focus
            ? Encouragement.cycleProgress(left: sessionsLeftInCycle, nextPhase: phase, nextMinutes: nextMinutes)
            : nil
        notifier.announce(finished: finished,
                          next: phase,
                          nextMinutes: nextMinutes,
                          autoStarted: state == .running,
                          todayCount: stats.today.pomodoros,
                          progress: progress,
                          tip: visibleBreakTip)

        if finished == .focus, settings.celebrateSessions {
            let today = stats.today.pomodoros
            let best = stats.bestPreviousDay
            onFocusCompleted?(Celebration(
                completedInCycle: completedInCycle,
                cycleLength: settings.sessionsBeforeLongBreak,
                todayCount: today,
                isPersonalBest: best > 0 && today == best + 1,
                nextPhase: phase,
                nextMinutes: nextMinutes,
                tip: visibleBreakTip
            ))
        }
    }

    private func advance(completed: Bool) {
        switch phase {
        case .focus:
            if completed { completedInCycle += 1 }
            phase = completedInCycle >= settings.sessionsBeforeLongBreak ? .longBreak : .shortBreak
        case .shortBreak:
            phase = .focus
        case .longBreak:
            completedInCycle = 0
            phase = .focus
        }
        breakTip = BreakIdeas.random(for: phase)
        state = .idle

        let autoStart = phase.isBreak ? settings.autoStartBreaks : settings.autoStartFocus
        if completed && autoStart {
            start()
        } else {
            syncBlocker()
        }
    }

    private func syncBlocker() {
        blocker.setFocusActive(state == .running && phase == .focus)
    }

    private func startTicker() {
        stopTicker()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.05
        // .common so the countdown keeps updating while menus are being tracked.
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }
}
