import AppKit
import Combine
import SwiftUI

enum ScreenCorner: String, CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight
    var id: String { rawValue }
    var label: String {
        switch self {
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        }
    }
    var symbol: String {
        switch self {
        case .topLeft: return "arrow.up.left"
        case .topRight: return "arrow.up.right"
        case .bottomLeft: return "arrow.down.left"
        case .bottomRight: return "arrow.down.right"
        }
    }
    var isLeft: Bool { self == .topLeft || self == .bottomLeft }
    var isTop: Bool { self == .topLeft || self == .topRight }
}

/// Borderless, always-on-top panel that never steals focus from the app you're working in.
final class WidgetPanel: NSPanel {
    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { true }
}

/// Lets the first click on the widget press a button even though the app isn't active.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class FloatingWidgetController {
    private static let originKey = "widgetOrigin"
    private static let margin: CGFloat = 16

    private let settings: AppSettings
    private let timer: PomodoroTimer
    private var panel: WidgetPanel?
    private var host: NSView?
    private var dragOffset: NSPoint?
    private var cancellables = Set<AnyCancellable>()

    init(settings: AppSettings, timer: PomodoroTimer) {
        self.settings = settings
        self.timer = timer
    }

    /// Call once the app has finished launching.
    func start() {
        settings.$displayMode
            .removeDuplicates()
            .sink { [weak self] mode in
                MainActor.assumeIsolated { self?.setVisible(mode.showsWidget) }
            }
            .store(in: &cancellables)
        settings.$widgetOpacity
            .sink { [weak self] value in
                MainActor.assumeIsolated { self?.panel?.alphaValue = value }
            }
            .store(in: &cancellables)
        settings.$widgetSize
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                // @Published fires before the value is stored; resize once SwiftUI has re-rendered.
                DispatchQueue.main.async { self?.fitToContent() }
            }
            .store(in: &cancellables)
        // The break-idea line changes the widget's height.
        timer.$breakTip.map { _ in () }
            .merge(with: settings.$showBreakTips.map { _ in () })
            .dropFirst(2)
            .sink { [weak self] in
                DispatchQueue.main.async { self?.fitToContent() }
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.keepOnScreen() }
            }
            .store(in: &cancellables)
    }

    /// The widget's frame while it's on screen, used to place the reward card next to it.
    var visibleFrame: NSRect? {
        guard let panel, panel.isVisible else { return nil }
        return panel.frame
    }

    func move(to corner: ScreenCorner) {
        guard let panel else { return }
        place(panel, at: corner)
        saveOrigin()
    }

    // MARK: Dragging (driven by a SwiftUI DragGesture so buttons keep working)

    func dragChanged() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        if dragOffset == nil {
            dragOffset = NSPoint(x: mouse.x - panel.frame.minX, y: mouse.y - panel.frame.minY)
        }
        guard let offset = dragOffset else { return }
        panel.setFrameOrigin(NSPoint(x: mouse.x - offset.x, y: mouse.y - offset.y))
    }

    func dragEnded() {
        dragOffset = nil
        keepOnScreen()
        saveOrigin()
    }

    // MARK: Internals

    private func setVisible(_ visible: Bool) {
        guard visible else {
            panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? makePanel()
        panel.alphaValue = settings.widgetOpacity
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        keepOnScreen()
    }

    private func makePanel() -> WidgetPanel {
        let root = FloatingWidgetView(controller: self)
            .environmentObject(timer)
            .environmentObject(settings)
            .environmentObject(AppState.shared.stats)
        let host = FirstMouseHostingView(rootView: root)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)

        let panel = WidgetPanel(size: size)
        panel.contentView = host
        self.panel = panel
        self.host = host

        if let saved = UserDefaults.standard.array(forKey: Self.originKey) as? [Double], saved.count == 2 {
            panel.setFrameOrigin(NSPoint(x: saved[0], y: saved[1]))
        } else {
            place(panel, at: .topRight)
        }
        return panel
    }

    /// Resize the panel to the SwiftUI content, keeping the top-left corner where the user put it.
    private func fitToContent() {
        guard let panel, let host else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let top = panel.frame.maxY
        panel.setFrame(NSRect(x: panel.frame.minX, y: top - size.height, width: size.width, height: size.height),
                       display: true)
        panel.invalidateShadow()
        keepOnScreen()
        saveOrigin()
    }

    private func place(_ panel: NSWindow, at corner: ScreenCorner) {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let area = screen.visibleFrame
        let size = panel.frame.size
        let x = corner.isLeft ? area.minX + Self.margin : area.maxX - size.width - Self.margin
        let y = corner.isTop ? area.maxY - size.height - Self.margin : area.minY + Self.margin
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Pull the widget fully back onto the nearest screen (e.g. after unplugging a display).
    private func keepOnScreen() {
        guard let panel, panel.isVisible else { return }
        let frame = panel.frame
        let center = NSPoint(x: frame.midX, y: frame.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.main else { return }
        let area = screen.visibleFrame
        let x = min(max(frame.minX, area.minX), area.maxX - frame.width)
        let y = min(max(frame.minY, area.minY), area.maxY - frame.height)
        if x != frame.minX || y != frame.minY {
            panel.setFrameOrigin(NSPoint(x: x, y: y))
            saveOrigin()
        }
    }

    private func saveOrigin() {
        guard let origin = panel?.frame.origin else { return }
        UserDefaults.standard.set([Double(origin.x), Double(origin.y)], forKey: Self.originKey)
    }
}

// MARK: - Views

/// Dimensions for each widget size.
private struct WidgetMetrics {
    let width: CGFloat
    let timeFont: CGFloat
    let labelFont: CGFloat
    let playButton: CGFloat
    let smallButton: CGFloat
    let hPadding: CGFloat
    let vPadding: CGFloat
    let corner: CGFloat
    let barHeight: CGFloat
    let dot: CGFloat
    let spacing: CGFloat
    /// Mini puts the phase icon inline and drops the label row, hover buttons and dots.
    let isMini: Bool

    init(_ size: WidgetSize) {
        switch size {
        case .mini:
            self.init(width: 140, timeFont: 18, labelFont: 11, playButton: 22, smallButton: 0,
                      hPadding: 10, vPadding: 7, corner: 10, barHeight: 3, dot: 0, spacing: 5, isMini: true)
        case .compact:
            self.init(width: 196, timeFont: 24, labelFont: 9, playButton: 28, smallButton: 22,
                      hPadding: 11, vPadding: 9, corner: 13, barHeight: 4, dot: 5, spacing: 6, isMini: false)
        case .regular:
            self.init(width: 270, timeFont: 34, labelFont: 10, playButton: 36, smallButton: 26,
                      hPadding: 14, vPadding: 12, corner: 16, barHeight: 6, dot: 6, spacing: 9, isMini: false)
        }
    }

    private init(width: CGFloat, timeFont: CGFloat, labelFont: CGFloat, playButton: CGFloat, smallButton: CGFloat,
                 hPadding: CGFloat, vPadding: CGFloat, corner: CGFloat, barHeight: CGFloat, dot: CGFloat,
                 spacing: CGFloat, isMini: Bool) {
        self.width = width; self.timeFont = timeFont; self.labelFont = labelFont
        self.playButton = playButton; self.smallButton = smallButton
        self.hPadding = hPadding; self.vPadding = vPadding; self.corner = corner
        self.barHeight = barHeight; self.dot = dot; self.spacing = spacing; self.isMini = isMini
    }
}

struct FloatingWidgetView: View {
    let controller: FloatingWidgetController
    @EnvironmentObject private var timer: PomodoroTimer
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var stats: StatsStore
    @State private var hovering = false

    private var m: WidgetMetrics { WidgetMetrics(settings.widgetSize) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: m.corner)
        VStack(alignment: .leading, spacing: m.spacing) {
            HStack(alignment: .center, spacing: m.isMini ? 6 : 8) {
                if m.isMini {
                    Image(systemName: timer.state == .paused ? "pause.circle.fill" : timer.phase.symbol)
                        .font(.system(size: m.labelFont, weight: .bold))
                        .foregroundStyle(timer.phase.color)
                    timeText
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        phaseLabel
                        timeText
                    }
                }
                Spacer(minLength: 0)
                controls
            }

            HStack(spacing: 8) {
                progressBar
                if !m.isMini {
                    cycleDots
                    if let goal = settings.activeDailyGoal {
                        goalBadge(goal)
                    }
                }
            }

            if !m.isMini, let tip = timer.visibleBreakTip {
                Label {
                    Text(tip)
                } icon: {
                    Image(systemName: timer.phase == .longBreak ? "figure.walk" : "leaf.fill")
                        .foregroundStyle(timer.phase.color)
                }
                .font(.system(size: m.labelFont + 1))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, m.hPadding)
        .padding(.vertical, m.vPadding)
        .frame(width: m.width)
        .background(VisualEffectBackground(cornerRadius: m.corner))
        .overlay(shape.strokeBorder(Color.primary.opacity(0.1)))
        .clipShape(shape)
        .contentShape(shape)
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { _ in controller.dragChanged() }
                .onEnded { _ in controller.dragEnded() }
        )
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.15)) { hovering = inside }
        }
        .contextMenu { WidgetMenuItems(controller: controller) }
        .help(helpText)
    }

    private var helpText: String {
        var text = timer.phase.title
        if let tip = timer.visibleBreakTip { text += ": \(tip)" }
        else if timer.phase == .focus {
            text += " · \(timer.sessionsLeftInCycle) left to a full cycle"
        }
        return text + "\nDrag to move · right-click for options"
    }

    private var phaseLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: timer.phase.symbol)
            Text(timer.alarmRinging ? "BREAK'S OVER" : timer.phase.title.uppercased()).tracking(0.5)
            if timer.cycleCommitted {
                Image(systemName: "lock.fill")
                    .imageScale(.small)
                    .help("Committed to this full cycle")
            }
            if timer.state == .paused {
                Text("· PAUSED").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: m.labelFont, weight: .bold))
        .foregroundStyle(timer.phase.color)
        .lineLimit(1)
    }

    private var timeText: some View {
        Text(timer.timeString)
            .font(.system(size: m.timeFont, weight: .semibold, design: .rounded))
            .monospacedDigit()
    }

    private var controls: some View {
        HStack(spacing: 5) {
            if !m.isMini {
                Group {
                    Button { timer.skip() } label: {
                        Image(systemName: "forward.end.fill")
                            .frame(width: m.smallButton, height: m.smallButton)
                            .background(Circle().fill(Color.primary.opacity(0.08)))
                    }
                    .help(timer.phase.isBreak ? "Skip break" : "Skip to break")

                    Menu {
                        WidgetMenuItems(controller: controller)
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: m.smallButton, height: m.smallButton)
                            .background(Circle().fill(Color.primary.opacity(0.08)))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
            }

            Button { timer.toggle() } label: {
                Image(systemName: timer.state == .running ? "pause.fill" : "play.fill")
                    .font(.system(size: m.playButton * 0.4, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: m.playButton, height: m.playButton)
                    .background(Circle().fill(timer.phase.color))
            }
            .help(timer.primaryActionTitle)
        }
        .buttonStyle(.plain)
        .font(.system(size: max(9, m.smallButton * 0.42), weight: .semibold))
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule()
                    .fill(timer.phase.color)
                    .frame(width: geo.size.width * timer.progress)
                    .animation(.linear(duration: 0.25), value: timer.progress)
            }
        }
        .frame(height: m.barHeight)
    }

    private func goalBadge(_ goal: Int) -> some View {
        let today = stats.today.pomodoros
        let met = today >= goal
        return Text(met ? "🏆 \(today)" : "\(today)/\(goal)")
            .font(.system(size: m.labelFont, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(met ? Color.orange : Color.secondary)
            .help(met ? "Daily goal of \(goal) reached" : "\(today) of \(goal) pomodoros today")
    }

    private var cycleDots: some View {
        HStack(spacing: 3) {
            ForEach(0..<settings.sessionsBeforeLongBreak, id: \.self) { i in
                Circle()
                    .fill(i < timer.completedInCycle ? Phase.focus.color : Color.primary.opacity(0.18))
                    .frame(width: m.dot, height: m.dot)
            }
        }
        .help("\(timer.completedInCycle) of \(settings.sessionsBeforeLongBreak) sessions before a long break")
    }
}

/// Shared by the right-click menu and the "…" button.
struct WidgetMenuItems: View {
    let controller: FloatingWidgetController
    @EnvironmentObject private var timer: PomodoroTimer
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Button(timer.primaryActionTitle) { timer.toggle() }
        Button("Restart \(timer.phase.isBreak ? "Break" : "Session")") { timer.reset() }
            .disabled(timer.state == .idle)
        Button(timer.phase.isBreak ? "Skip Break" : "Skip to Break") { timer.skip() }
        Button("Reset Cycle") { timer.resetCycle() }
        if timer.cycleCommitted {
            Button("End Full-Cycle Commitment") { timer.endCommitment() }
        } else {
            Button("Commit to Full Cycle") { timer.commitToCycle() }
        }
        Divider()
        Menu("Move to Corner") {
            ForEach(ScreenCorner.allCases) { corner in
                Button(corner.label) { controller.move(to: corner) }
            }
        }
        if settings.displayMode == .both {
            Button("Hide Widget (keep menu bar)") { settings.displayMode = .menuBar }
        } else {
            Button("Also Show in Menu Bar") { settings.displayMode = .both }
        }
        Divider()
        Button("Jot Down a Thought…") { AppState.shared.notepad.showCapture() }
        Button("Statistics…") { SettingsWindowController.shared.show(.stats) }
        Button("Settings…") { SettingsWindowController.shared.show(.display) }
        Divider()
        Button("Quit Pomodoro") { NSApp.terminate(nil) }
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
