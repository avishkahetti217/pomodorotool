import AppKit
import Combine
import SwiftUI

/// Turns a macOS Focus (e.g. Do Not Disturb) on during focus sessions by running two user-made
/// Shortcuts via `/usr/bin/shortcuts`. macOS has no public API for setting Focus directly,
/// so Shortcuts is the supported route.
@MainActor
final class FocusModeController: ObservableObject {
    static let defaultOnName = "Pomodoro Focus On"
    static let defaultOffName = "Pomodoro Focus Off"
    nonisolated private static let cli = "/usr/bin/shortcuts"
    /// Coalesces quick changes (e.g. skip → start) into a single shortcut run.
    private static let debounce: TimeInterval = 0.8

    @Published private(set) var availableShortcuts: [String] = []
    @Published private(set) var lastError: String?
    /// Whether we've switched Focus on (so we only ever turn off what we turned on).
    @Published private(set) var isOn = false

    private let timer: PomodoroTimer
    private let settings: AppSettings
    private var pending: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()

    init(timer: PomodoroTimer, settings: AppSettings) {
        self.timer = timer
        self.settings = settings
    }

    func start() {
        timer.$phase.map { _ in () }
            .merge(with: timer.$state.map { _ in () },
                   settings.$focusModeEnabled.map { _ in () },
                   settings.$focusModeDuringBreaks.map { _ in () })
            .sink { [weak self] in
                DispatchQueue.main.async { self?.evaluate() }
            }
            .store(in: &cancellables)
        refreshShortcuts()
    }

    var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: Self.cli) }

    var onShortcutFound: Bool { availableShortcuts.contains(settings.focusOnShortcut) }
    var offShortcutFound: Bool { availableShortcuts.contains(settings.focusOffShortcut) }

    private var shouldBeOn: Bool {
        guard settings.focusModeEnabled else { return false }
        switch timer.phase {
        case .focus:
            return timer.state == .running
        case .shortBreak, .longBreak:
            return settings.focusModeDuringBreaks && timer.state != .idle
        }
    }

    private func evaluate() {
        pending?.cancel()
        let target = shouldBeOn
        guard target != isOn else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.shouldBeOn == target, target != self.isOn else { return }
            self.isOn = target
            self.run(target ? self.settings.focusOnShortcut : self.settings.focusOffShortcut)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounce, execute: work)
    }

    /// Manual test from Settings.
    func test(on: Bool) {
        run(on ? settings.focusOnShortcut : settings.focusOffShortcut)
    }

    /// Called on quit so Focus isn't left on after the app is gone.
    func turnOffIfNeeded() {
        guard isOn else { return }
        isOn = false
        _ = Self.runSync([ "run", settings.focusOffShortcut ], timeout: 5)
    }

    func refreshShortcuts() {
        guard isAvailable else { return }
        DispatchQueue.global(qos: .utility).async {
            let result = Self.runSync(["list"], timeout: 10)
            let names = result.output
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.availableShortcuts = names }
            }
        }
    }

    private func run(_ name: String) {
        guard isAvailable else {
            lastError = "The Shortcuts command-line tool isn't available on this Mac."
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.runSync(["run", name], timeout: 20)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if result.status == 0 {
                        self.lastError = nil
                    } else {
                        let detail = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
                        self.lastError = "Couldn't run “\(name)”" + (detail.isEmpty ? "." : ": \(detail)")
                    }
                }
            }
        }
    }

    private struct RunResult {
        var status: Int32
        var output: String
        var error: String
    }

    nonisolated private static func runSync(_ arguments: [String], timeout: TimeInterval) -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            return RunResult(status: -1, output: "", error: error.localizedDescription)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            return RunResult(status: -1, output: "", error: "Timed out")
        }
        let output = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return RunResult(status: process.terminationStatus, output: output, error: error)
    }
}

// MARK: - Settings UI

struct FocusModeSettingsSection: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var focus = AppState.shared.focusMode
    @State private var showSetup = false

    var body: some View {
        Section {
            Toggle("Turn on macOS Focus during focus sessions", isOn: $settings.focusModeEnabled)

            Group {
                shortcutPicker("Turn on with", selection: $settings.focusOnShortcut, found: focus.onShortcutFound)
                shortcutPicker("Turn off with", selection: $settings.focusOffShortcut, found: focus.offShortcutFound)
                Toggle("Keep Focus on during breaks", isOn: $settings.focusModeDuringBreaks)

                HStack {
                    Button("Test On") { focus.test(on: true) }
                    Button("Test Off") { focus.test(on: false) }
                    Spacer()
                    Button {
                        focus.refreshShortcuts()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    Button("Open Shortcuts") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Shortcuts.app"))
                    }
                }

                if let error = focus.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .disabled(!settings.focusModeEnabled)

            DisclosureGroup("How to set it up (one time, about a minute)", isExpanded: $showSetup) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. Click **Open Shortcuts**, then **File → New Shortcut**.")
                    Text("2. Name it **\(FocusModeController.defaultOnName)**. Search actions for **Set Focus**, add it, and set it to **Turn Do Not Disturb On** (or pick another Focus) **until Turned Off**.")
                    Text("3. Make a second shortcut named **\(FocusModeController.defaultOffName)** with **Set Focus → Turn Do Not Disturb Off**.")
                    Text("4. Come back here, click **Refresh**, then **Test On** / **Test Off**.")
                }
                .font(.caption)
                .padding(.top, 4)
            }
        } header: {
            Text("macOS Focus mode")
        } footer: {
            Text("Focus switches on when a focus session starts or resumes, and off when it's paused, skipped, finished, or when you quit Pomodoro. macOS only lets apps change Focus through the Shortcuts app, which is why the two shortcuts are needed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { focus.refreshShortcuts() }
    }

    private func shortcutPicker(_ title: String, selection: Binding<String>, found: Bool) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Image(systemName: found ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(found ? .green : .orange)
                    .help(found ? "Shortcut found" : "No shortcut with this name yet. See the setup steps below.")
                Picker(title, selection: selection) {
                    if !focus.availableShortcuts.contains(selection.wrappedValue) {
                        Text("\(selection.wrappedValue) (not found)").tag(selection.wrappedValue)
                    }
                    ForEach(focus.availableShortcuts, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
            }
        }
    }
}
