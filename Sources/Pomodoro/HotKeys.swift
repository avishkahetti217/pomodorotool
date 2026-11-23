import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

enum HotKeyAction: String, CaseIterable, Identifiable, Codable {
    case toggle, skip, restart
    var id: String { rawValue }

    var label: String {
        switch self {
        case .toggle: return "Start / Pause"
        case .skip: return "Skip to next phase"
        case .restart: return "Restart current session"
        }
    }

    var numericID: UInt32 {
        switch self {
        case .toggle: return 1
        case .skip: return 2
        case .restart: return 3
        }
    }

    init?(numericID: UInt32) {
        guard let match = Self.allCases.first(where: { $0.numericID == numericID }) else { return nil }
        self = match
    }
}

/// A key combination, stored with Carbon modifier flags so it can be registered system-wide.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    /// Human-readable key, captured when recorded (e.g. "P", "Space", "→").
    var key: String

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + key
    }

    static let defaults: [String: Shortcut] = [
        HotKeyAction.toggle.rawValue: Shortcut(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(controlKey | optionKey), key: "P"),
        HotKeyAction.skip.rawValue: Shortcut(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(controlKey | optionKey), key: "S"),
        HotKeyAction.restart.rawValue: Shortcut(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(controlKey | optionKey), key: "R"),
    ]

    /// Builds a shortcut from a key press; nil if it lacks ⌘, ⌥ or ⌃ (too easy to trigger by accident).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        self.init(keyCode: UInt32(event.keyCode), modifiers: mods, key: Self.keyName(for: event))
    }

    init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    private static func keyName(for event: NSEvent) -> String {
        let special: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        if let name = special[Int(event.keyCode)] { return name }
        return (event.charactersIgnoringModifiers ?? "?").uppercased()
    }
}

/// Registers global hotkeys with the Carbon Event Manager. Works from any app and,
/// unlike key-event monitoring, needs no Accessibility permission.
@MainActor
final class HotKeyManager: ObservableObject {
    /// Actions whose shortcut couldn't be registered (usually already taken by another app).
    @Published private(set) var conflicts: Set<HotKeyAction> = []

    private static weak var current: HotKeyManager?
    private static let signature: OSType = 0x504F_4D4F // "POMO"

    private let settings: AppSettings
    private let timer: PomodoroTimer
    private let widget: FloatingWidgetController
    private let feedback: CardPresenter
    private var refs: [HotKeyAction: EventHotKeyRef] = [:]
    private var handlerInstalled = false
    private var suspended = false
    private var subscription: AnyCancellable?

    init(settings: AppSettings, timer: PomodoroTimer, widget: FloatingWidgetController) {
        self.settings = settings
        self.timer = timer
        self.widget = widget
        self.feedback = CardPresenter(widget: widget)
    }

    func start() {
        Self.current = self
        installHandler()
        subscription = settings.$shortcuts.sink { [weak self] shortcuts in
            MainActor.assumeIsolated { self?.registerAll(shortcuts) }
        }
    }

    /// Temporarily release all hotkeys, e.g. while recording a new one.
    func suspend() {
        suspended = true
        unregisterAll()
    }

    func resume() {
        suspended = false
        registerAll(settings.shortcuts)
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotKeyManager.current?.fire(id) }
            }
            return noErr
        }, 1, &spec, nil, nil)
        handlerInstalled = true
    }

    private func registerAll(_ shortcuts: [String: Shortcut]) {
        unregisterAll()
        guard !suspended else { return }
        var failed = Set<HotKeyAction>()
        for action in HotKeyAction.allCases {
            guard let shortcut = shortcuts[action.rawValue] else { continue }
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
                                             EventHotKeyID(signature: Self.signature, id: action.numericID),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs[action] = ref
            } else {
                failed.insert(action)
            }
        }
        conflicts = failed
    }

    private func unregisterAll() {
        refs.values.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
    }

    private func fire(_ id: UInt32) {
        guard let action = HotKeyAction(numericID: id) else { return }
        switch action {
        case .toggle: timer.toggle()
        case .skip: timer.skip()
        case .restart: timer.reset()
        }
        showFeedback(for: action)
    }

    /// A brief confirmation card, only when the widget isn't already showing the change.
    private func showFeedback(for action: HotKeyAction) {
        guard widget.visibleFrame == nil else { return }
        let symbol: String
        let title: String
        switch action {
        case .toggle:
            symbol = timer.state == .running ? "play.fill" : "pause.fill"
            title = timer.state == .running ? "\(timer.phase.title) started" : "Paused"
        case .skip:
            symbol = "forward.end.fill"
            title = "Up next: \(timer.phase.title)"
        case .restart:
            symbol = "arrow.counterclockwise"
            title = "\(timer.phase.title) restarted"
        }
        feedback.show(HotKeyFeedbackView(symbol: symbol, title: title, time: timer.timeString, color: timer.phase.color),
                      autoDismissAfter: 1.4)
    }
}

struct HotKeyFeedbackView: View {
    let symbol: String
    let title: String
    let time: String
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(color))
            Text(title).font(.callout.weight(.semibold))
            Spacer(minLength: 8)
            Text(time)
                .font(.system(.callout, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(width: 240)
        .background(VisualEffectBackground(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.1)))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// Click, then press a key combination. Esc cancels; ⌫ clears.
struct ShortcutRecorder: View {
    let action: HotKeyAction
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var hotkeys = AppState.shared.hotkeys
    @State private var recording = false
    @State private var monitor: Any?

    private var shortcut: Shortcut? { settings.shortcuts[action.rawValue] }

    var body: some View {
        HStack(spacing: 6) {
            if hotkeys.conflicts.contains(action), !recording {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Another app is already using this shortcut. Pick a different one.")
            }
            Button {
                recording ? stopRecording() : startRecording()
            } label: {
                Text(recording ? "Type shortcut…" : (shortcut?.display ?? "Not set"))
                    .monospacedDigit()
                    .foregroundStyle(recording ? Color.accentColor : (shortcut == nil ? Color.secondary : Color.primary))
                    .frame(minWidth: 110)
            }
            .help(recording ? "Press a combination with ⌘, ⌥ or ⌃. Esc cancels, ⌫ clears." : "Click to change")

            Button {
                settings.shortcuts[action.rawValue] = nil
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove shortcut")
            .opacity(shortcut == nil || recording ? 0 : 1)
            .disabled(shortcut == nil || recording)
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        hotkeys.suspend()
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil
        }
    }

    private func handle(_ event: NSEvent) {
        let bare = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
        if event.keyCode == UInt16(kVK_Escape) {
            stopRecording()
        } else if bare && (event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete)) {
            settings.shortcuts[action.rawValue] = nil
            stopRecording()
        } else if let new = Shortcut(event: event) {
            // Assigning a combo already used by another action moves it here.
            for (key, existing) in settings.shortcuts where existing == new && key != action.rawValue {
                settings.shortcuts[key] = nil
            }
            settings.shortcuts[action.rawValue] = new
            stopRecording()
        } else {
            NSSound.beep()
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording {
            recording = false
            hotkeys.resume()
        }
    }
}
