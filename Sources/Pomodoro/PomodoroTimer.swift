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

/// Describes a focus session that was auto-paused because the user stepped away.
struct AwayReport: Equatable {
    let since: Date
    let returnedAt: Date
    var duration: TimeInterval { returnedAt.timeIntervalSince(since) }
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

    /// The current cycle must be completed: the end of each short break rings an alarm until focus resumes.
    @Published private(set) var cycleCommitted = false
    /// True while the "break's over" alarm is ringing.
    @Published private(set) var alarmRinging = false

    /// Set when the user comes back after an auto-pause; cleared once they choose what to do.
    @Published private(set) var awayReport: AwayReport?

    /// Called after a focus session completes (used for the reward card).
    var onFocusCompleted: ((Celebration) -> Void)?

    private var awaySince: Date?
    private var returnWatch: Timer?
    private var screenLocked = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

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
        cycleCommitted = settings.commitFullCycle
        // Flipping the setting applies to the cycle in progress too.
        settings.$commitFullCycle
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] on in
                MainActor.assumeIsolated { on ? self?.commitToCycle() : self?.endCommitment() }
            }
            .store(in: &cancellables)
        observeSleepAndLock()
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
        alarmRinging = false
        clearAway()
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
        alarmRinging = false
        clearAway()
        stopTicker()
        endDate = nil
        state = .idle
        syncBlocker()
    }

    /// Move to the next phase without counting the current one as completed.
    func skip() {
        alarmRinging = false
        clearAway()
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
        cycleCommitted = settings.commitFullCycle
    }

    // MARK: - Full-cycle commitment

    func commitToCycle() {
        cycleCommitted = true
    }

    /// Drop the commitment for this cycle (e.g. something urgent came up). Stops any alarm.
    func endCommitment() {
        cycleCommitted = false
        alarmRinging = false
    }

    // MARK: - Away handling

    /// Resume from where the user left; the time away is not counted.
    func resumeIgnoringAway() {
        start()
    }

    /// Treat the time away as focus time (e.g. thinking on a whiteboard or a work call).
    func resumeCountingAway() {
        guard let report = awayReport else { return start() }
        let left = pausedRemaining - report.duration
        clearAway()
        if left <= 0 {
            finish()
        } else {
            pausedRemaining = left
            start()
        }
    }

    /// Keep the session paused and just dismiss the prompt.
    func dismissAway() {
        clearAway()
    }

    private func clearAway() {
        awaySince = nil
        awayReport = nil
        returnWatch?.invalidate()
        returnWatch = nil
    }

    /// Pause a running focus session as of the moment the user left.
    private func pauseForAway(since start: Date) {
        guard settings.idlePauseEnabled, phase == .focus, state == .running, let end = endDate else { return }
        pausedRemaining = min(totalDuration, max(0, end.timeIntervalSince(start)))
        endDate = nil
        state = .paused
        stopTicker()
        syncBlocker()
        awaySince = start
        awayReport = nil
        watchForReturn()
    }

    private func watchForReturn() {
        returnWatch?.invalidate()
        let watch = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let since = self.awaySince else { return }
                guard !self.screenLocked, Self.systemIdleSeconds() < 3 else { return }
                self.returnWatch?.invalidate()
                self.returnWatch = nil
                self.awayReport = AwayReport(since: since, returnedAt: Date())
            }
        }
        RunLoop.main.add(watch, forMode: .common)
        returnWatch = watch
    }

    /// Seconds since the last keyboard/mouse/trackpad input. Needs no special permission.
    static func systemIdleSeconds() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    private func observeSleepAndLock() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let leave: (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.pauseForAway(since: Date()) }
        }
        for name in [NSWorkspace.willSleepNotification,
                     NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            observers.append((workspace, workspace.addObserver(forName: name, object: nil, queue: .main, using: leave)))
        }
        observers.append((distributed, distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                self?.screenLocked = true
                self?.pauseForAway(since: Date())
            }
        }))
        observers.append((distributed, distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenLocked = false }
        }))
    }

    // MARK: - Internals

    private func tick() {
        now = Date()
        if phase == .focus, settings.idlePauseEnabled {
            let idle = Self.systemIdleSeconds()
            if idle >= TimeInterval(settings.idleMinutes * 60) {
                pauseForAway(since: now.addingTimeInterval(-idle))
                return
            }
        }
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

        if finished == .shortBreak, cycleCommitted, state != .running {
            alarmRinging = true
        }
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
                          tip: visibleBreakTip,
                          goalReached: finished == .focus && settings.activeDailyGoal == stats.today.pomodoros)

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
                tip: visibleBreakTip,
                dailyGoal: settings.activeDailyGoal
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
            cycleCommitted = settings.commitFullCycle
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
