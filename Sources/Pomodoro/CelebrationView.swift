import AppKit
import SwiftUI

/// Shows a small floating card next to the widget (or top-center when the widget is hidden).
/// Cards never take keyboard focus. Optionally auto-dismiss; hovering pauses the countdown.
@MainActor
final class CardPresenter {
    private let widget: FloatingWidgetController
    private var panel: WidgetPanel?
    private var dismissWork: DispatchWorkItem?
    private var autoDismiss: TimeInterval?

    init(widget: FloatingWidgetController) {
        self.widget = widget
    }

    var isShowing: Bool { panel != nil }

    func show<Content: View>(_ content: Content, autoDismissAfter seconds: TimeInterval? = nil) {
        closeImmediately()
        autoDismiss = seconds

        let host = FirstMouseHostingView(rootView: content)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)

        let panel = WidgetPanel(size: size)
        panel.contentView = host
        panel.setFrameOrigin(origin(for: size))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        self.panel = panel

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 1
        }
        if let seconds { scheduleDismiss(after: seconds) }
    }

    /// Hovering keeps an auto-dismissing card open; leaving gives a short grace period.
    func hoverChanged(_ inside: Bool) {
        guard autoDismiss != nil else { return }
        if inside { dismissWork?.cancel() } else { scheduleDismiss(after: 2) }
    }

    func dismiss() {
        dismissWork?.cancel()
        guard let panel else { return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    private func scheduleDismiss(after seconds: TimeInterval) {
        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func closeImmediately() {
        dismissWork?.cancel()
        panel?.orderOut(nil)
        panel = nil
    }

    private func origin(for size: NSSize) -> NSPoint {
        let gap: CGFloat = 8
        if let anchor = widget.visibleFrame,
           let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main {
            let area = screen.visibleFrame
            let x = min(max(anchor.midX - size.width / 2, area.minX + gap), area.maxX - size.width - gap)
            var y = anchor.minY - gap - size.height
            if y < area.minY { y = anchor.maxY + gap }
            return NSPoint(x: x, y: min(y, area.maxY - size.height))
        }
        let area = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        return NSPoint(x: area.midX - size.width / 2, y: area.maxY - size.height - 12)
    }
}

/// Shows the reward card after a focus session.
@MainActor
final class CelebrationController {
    private let cards: CardPresenter

    init(widget: FloatingWidgetController) {
        cards = CardPresenter(widget: widget)
    }

    func show(_ celebration: Celebration) {
        let view = CelebrationView(
            celebration: celebration,
            onHover: { [weak cards] in cards?.hoverChanged($0) },
            onClose: { [weak cards] in cards?.dismiss() }
        )
        cards.show(view, autoDismissAfter: celebration.isGoalReached ? 9 : 6)
    }
}

struct CelebrationView: View {
    let celebration: Celebration
    let onHover: (Bool) -> Void
    let onClose: () -> Void

    @State private var appeared = false
    @State private var headline = ""

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    ConfettiBurst(active: appeared, big: celebration.isGoalReached)
                    Text(celebration.emoji)
                        .font(.system(size: 30))
                        .scaleEffect(appeared ? 1 : 0.3)
                        .rotationEffect(.degrees(appeared ? 0 : -30))
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 5) {
                    Text(headline).font(.headline)
                    cycleDots
                    Text(celebration.progressText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 4) {
                Text(celebration.todayText)
                if celebration.isPersonalBest {
                    Text("· New personal best! 🏆").foregroundStyle(.orange)
                }
            }
            .font(.caption.weight(.semibold))

            if let tip = celebration.tip {
                Divider()
                Label {
                    Text("Break idea: \(tip)")
                } icon: {
                    Image(systemName: celebration.nextPhase == .longBreak ? "figure.walk" : "leaf.fill")
                        .foregroundStyle(celebration.nextPhase.color)
                }
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 280)
        .background(VisualEffectBackground(cornerRadius: 14))
        .overlay(shape.strokeBorder(Color.primary.opacity(0.1)))
        .clipShape(shape)
        .contentShape(shape)
        .onTapGesture(perform: onClose)
        .onHover(perform: onHover)
        .help("Click to dismiss")
        .onAppear {
            headline = celebration.headline
            withAnimation(.spring(response: 0.5, dampingFraction: 0.55).delay(0.05)) {
                appeared = true
            }
        }
    }

    private var cycleDots: some View {
        HStack(spacing: 5) {
            ForEach(0..<celebration.cycleLength, id: \.self) { i in
                let isNew = i == celebration.completedInCycle - 1
                Circle()
                    .fill(i < celebration.completedInCycle ? Phase.focus.color : Color.primary.opacity(0.18))
                    .frame(width: 8, height: 8)
                    .scaleEffect(isNew && !appeared ? 0.1 : 1)
            }
        }
    }
}

/// A small one-shot burst of dots radiating from the center.
struct ConfettiBurst: View {
    let active: Bool
    var big = false
    private var count: Int { big ? 24 : 14 }
    private let colors: [Color] = [Phase.focus.color, .orange, .yellow, Phase.shortBreak.color, Phase.longBreak.color]

    var body: some View {
        ZStack {
            ForEach(0..<count, id: \.self) { i in
                let angle = Double(i) / Double(count) * 2 * .pi
                let distance: CGFloat = (i.isMultiple(of: 2) ? 30 : 22) * (big ? 1.4 : 1)
                Circle()
                    .fill(colors[i % colors.count])
                    .frame(width: 5, height: 5)
                    .offset(x: active ? cos(angle) * distance : 0,
                            y: active ? sin(angle) * distance : 0)
                    .opacity(active ? 0 : 1)
            }
        }
        .animation(.easeOut(duration: 1.0), value: active)
        .allowsHitTesting(false)
    }
}
