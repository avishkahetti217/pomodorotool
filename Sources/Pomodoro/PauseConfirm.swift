import AppKit
import Combine
import SwiftUI

/// Asks "are you sure?" before a running focus session is paused by hand.
/// The timer keeps running while the question is up; the safe choice is the default.
@MainActor
final class PauseConfirmController: NSObject, NSWindowDelegate {
    private let timer: PomodoroTimer
    private let settings: AppSettings
    private let notepad: NotepadController
    private var panel: WidgetPanel?
    private var subscription: AnyCancellable?

    init(timer: PomodoroTimer, settings: AppSettings, notepad: NotepadController) {
        self.timer = timer
        self.settings = settings
        self.notepad = notepad
        super.init()
        // If the session ends or changes while the question is open, the question no longer applies.
        subscription = timer.$state.map { _ in () }
            .merge(with: timer.$phase.map { _ in () })
            .sink { [weak self] in
                DispatchQueue.main.async {
                    guard let self, self.panel != nil else { return }
                    if self.timer.state != .running || self.timer.phase != .focus { self.close() }
                }
            }
    }

    func ask() {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let view = PauseConfirmView(
            timer: timer,
            settings: settings,
            onKeepFocusing: { [weak self] in self?.close() },
            onPark: { [weak self] in
                self?.close()
                self?.notepad.showCapture()
            },
            onPause: { [weak self] in
                self?.close()
                self?.timer.pause()
            }
        )
        let host = FirstMouseHostingView(rootView: view)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)

        let panel = WidgetPanel(size: size)
        panel.contentView = host
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.becomesKeyOnlyIfNeeded = false
        panel.delegate = self

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let area = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2,
                                         y: area.midY - size.height / 2 + area.height * 0.1))
        }
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        NSSound(named: "Tink")?.play()
    }

    private func close() {
        guard let panel else { return }
        self.panel = nil
        panel.delegate = nil
        panel.orderOut(nil)
    }

    /// Clicking elsewhere counts as "keep focusing".
    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}

struct PauseConfirmView: View {
    @ObservedObject var timer: PomodoroTimer
    @ObservedObject var settings: AppSettings
    let onKeepFocusing: () -> Void
    let onPark: () -> Void
    let onPause: () -> Void

    private var noteHint: String {
        settings.shortcuts[HotKeyAction.capture.rawValue].map { " (\($0.display))" } ?? ""
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Pause this focus session?")
                        .font(.title3.weight(.semibold))
                    Text("You have **\(timer.timeString)** left. Is it truly impossible to park this distraction until the session ends?")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button(action: onPark) {
                Label("Park it with a note instead\(noteHint)", systemImage: "square.and.pencil")
                    .font(.callout)
            }
            .buttonStyle(.link)

            HStack {
                Button("Yes, pause", role: .destructive, action: onPause)
                    .help("Pause the session now")
                Spacer()
                Button("Keep focusing", action: onKeepFocusing)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Phase.focus.color)
            }
            .controlSize(.large)
        }
        .padding(20)
        .frame(width: 400)
        .background(VisualEffectBackground(cornerRadius: 16))
        .overlay(shape.strokeBorder(Color.orange.opacity(0.5), lineWidth: 1.5))
        .clipShape(shape)
        .onExitCommand(perform: onKeepFocusing)
    }
}
