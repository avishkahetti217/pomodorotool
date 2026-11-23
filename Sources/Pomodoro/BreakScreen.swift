import AppKit
import Combine
import SwiftUI

/// Dims every display during breaks (if enabled) and shows the break countdown on the main screen.
/// Sits above normal windows, the menu bar and the Dock; disappears as soon as the break ends.
@MainActor
final class BreakScreenController {
    /// Short pause before dimming, so the reward card is seen and you can finish a sentence.
    private static let showDelay: TimeInterval = 3

    private let timer: PomodoroTimer
    private let settings: AppSettings
    private let stats: StatsStore
    private var windows: [NSWindow] = []
    private var pendingShow: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()

    init(timer: PomodoroTimer, settings: AppSettings, stats: StatsStore) {
        self.timer = timer
        self.settings = settings
        self.stats = stats
    }

    func start() {
        // Re-evaluate whenever phase, run state or the setting changes (after the value has landed).
        timer.$phase.map { _ in () }
            .merge(with: timer.$state.map { _ in () },
                   settings.$breakScreenMode.map { _ in () })
            .sink { [weak self] in
                DispatchQueue.main.async { self?.evaluate() }
            }
            .store(in: &cancellables)
        settings.$breakScreenOpacity
            .sink { [weak self] value in
                MainActor.assumeIsolated {
                    // Dims only the background; the countdown text stays fully readable.
                    self?.windows.forEach { $0.backgroundColor = NSColor.black.withAlphaComponent(value) }
                }
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.windows.isEmpty else { return }
                    self.hide(animated: false)
                    self.show(animated: false)
                }
            }
            .store(in: &cancellables)
    }

    private var shouldShow: Bool {
        settings.breakScreenMode.applies(to: timer.phase) && timer.state != .idle
    }

    private func evaluate() {
        if shouldShow {
            guard windows.isEmpty, pendingShow == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingShow = nil
                if self.shouldShow { self.show(animated: true) }
            }
            pendingShow = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.showDelay, execute: work)
        } else {
            pendingShow?.cancel()
            pendingShow = nil
            hide(animated: true)
        }
    }

    private func show(animated: Bool) {
        guard windows.isEmpty else { return }
        let main = NSScreen.main ?? NSScreen.screens.first
        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.backgroundColor = NSColor.black.withAlphaComponent(settings.breakScreenOpacity)
            window.isOpaque = false
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.ignoresMouseEvents = false
            window.setFrame(screen.frame, display: false)

            if screen == main {
                let content = BreakScreenView(timer: timer, settings: settings, stats: stats)
                let host = FirstMouseHostingView(rootView: content)
                host.frame = NSRect(origin: .zero, size: screen.frame.size)
                window.contentView = host
            }

            window.alphaValue = animated ? 0 : 1
            window.orderFrontRegardless()
            windows.append(window)
        }
        guard animated else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.8
            windows.forEach { $0.animator().alphaValue = 1 }
        }
    }

    private func hide(animated: Bool) {
        guard !windows.isEmpty else { return }
        let closing = windows
        windows.removeAll()
        guard animated else {
            closing.forEach { $0.orderOut(nil) }
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.5
            closing.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: {
            closing.forEach { $0.orderOut(nil) }
        })
    }
}

struct BreakScreenView: View {
    @ObservedObject var timer: PomodoroTimer
    @ObservedObject var settings: AppSettings
    @ObservedObject var stats: StatsStore

    var body: some View {
        ZStack {
            Color.clear

            VStack(spacing: 26) {
                Label(timer.phase.title.uppercased(), systemImage: timer.phase.symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .tracking(4)
                    .foregroundStyle(timer.phase.color)

                Text(timer.timeString)
                    .font(.system(size: 132, weight: .thin, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)

                progressBar

                if let tip = timer.visibleBreakTip {
                    Text(tip)
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .multilineTextAlignment(.center)
                }

                Text(timer.state == .paused
                     ? "Break paused"
                     : "Step away from the screen. We'll bring it back when it's time.")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.5))

                Text(progressLine)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))

                controls
                    .padding(.top, 14)
            }
            .padding(40)
        }
    }

    private var progressBar: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.12))
            Capsule()
                .fill(timer.phase.color)
                .frame(width: 420 * timer.progress)
                .animation(.linear(duration: 0.25), value: timer.progress)
        }
        .frame(width: 420, height: 6)
    }

    private var progressLine: String {
        var parts: [String] = []
        if timer.phase == .longBreak {
            parts.append("Full cycle complete 🎉")
        } else {
            let left = timer.sessionsLeftInCycle
            parts.append(left == 1 ? "1 more session to a full cycle" : "\(left) more sessions to a full cycle")
        }
        let today = stats.today.pomodoros
        if let goal = settings.activeDailyGoal {
            parts.append("\(today) of \(goal) today")
        } else {
            parts.append("\(today) today")
        }
        return parts.joined(separator: "  ·  ")
    }

    private var controls: some View {
        HStack(spacing: 14) {
            if timer.state == .paused {
                Button("Resume break") { timer.start() }
                    .buttonStyle(BreakScreenButtonStyle(prominent: true))
            }
            if settings.breakScreenAllowSkip {
                Button("Skip break") { timer.skip() }
                    .buttonStyle(BreakScreenButtonStyle(prominent: false))
                    .help("End the break now")
            }
        }
    }
}

private struct BreakScreenButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white.opacity(prominent ? 1 : 0.7))
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.3 : prominent ? 0.22 : 0.1)))
            .contentShape(Capsule())
    }
}
