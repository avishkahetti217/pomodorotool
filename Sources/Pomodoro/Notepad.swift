import AppKit
import SwiftUI

struct DistractionNote: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var created = Date()
    var done = false
}

/// Thoughts parked during focus, persisted to UserDefaults.
@MainActor
final class NotesStore: ObservableObject {
    private static let storageKey = "distractionNotes"
    private let defaults = UserDefaults.standard

    @Published private(set) var notes: [DistractionNote] {
        didSet { defaults.set(try? JSONEncoder().encode(notes), forKey: Self.storageKey) }
    }

    init() {
        if let data = defaults.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([DistractionNote].self, from: data) {
            notes = saved
        } else {
            notes = []
        }
    }

    /// Open notes, oldest first (the order they were parked).
    var open: [DistractionNote] { notes.filter { !$0.done } }
    var completed: [DistractionNote] { notes.filter(\.done) }

    func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        notes.append(DistractionNote(text: trimmed))
    }

    func toggle(_ note: DistractionNote) {
        guard let i = notes.firstIndex(where: { $0.id == note.id }) else { return }
        notes[i].done.toggle()
    }

    func delete(_ note: DistractionNote) {
        notes.removeAll { $0.id == note.id }
    }

    func clearCompleted() {
        notes.removeAll(where: \.done)
    }

    var plainText: String {
        open.map { "- \($0.text)" }.joined(separator: "\n")
    }
}

/// The Spotlight-style capture box. A non-activating panel that can still take typing,
/// so you stay in the app you were working in.
@MainActor
final class NotepadController: NSObject, NSWindowDelegate {
    private let notes: NotesStore
    private var panel: WidgetPanel?

    init(notes: NotesStore) {
        self.notes = notes
    }

    func showCapture() {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let view = CaptureView(
            onSave: { [weak self] text in
                self?.notes.add(text)
                self?.closeCapture()
            },
            onCancel: { [weak self] in self?.closeCapture() }
        )
        .environmentObject(notes)
        let host = FirstMouseHostingView(rootView: view)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)

        let panel = WidgetPanel(size: size)
        panel.contentView = host
        // Above the break screen, so you can jot something down during a break too.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.becomesKeyOnlyIfNeeded = false
        panel.delegate = self

        // Upper-middle of the screen the mouse is on, like Spotlight.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let area = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2,
                                         y: area.minY + area.height * 0.68))
        }
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
    }

    func closeCapture() {
        guard let panel else { return }
        self.panel = nil
        panel.delegate = nil
        panel.orderOut(nil)
    }

    /// Clicking anywhere else dismisses it.
    func windowDidResignKey(_ notification: Notification) {
        closeCapture()
    }
}

struct CaptureView: View {
    let onSave: (String) -> Void
    let onCancel: () -> Void
    @EnvironmentObject private var notes: NotesStore
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Phase.focus.color)
                TextField("Park a thought and get back to work…", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18))
                    .focused($focused)
                    .onSubmit {
                        if text.trimmingCharacters(in: .whitespaces).isEmpty { onCancel() } else { onSave(text) }
                    }
                    .onExitCommand(perform: onCancel)
            }
            Text("↩ save  ·  esc cancel" + (notes.open.isEmpty ? "" : "  ·  \(notes.open.count) parked"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 520)
        .background(VisualEffectBackground(cornerRadius: 14))
        .overlay(shape.strokeBorder(Color.primary.opacity(0.12)))
        .clipShape(shape)
        .onAppear {
            DispatchQueue.main.async { focused = true }
        }
    }
}

/// A checklist of notes, reused by the popover, the Notes tab and the break screen.
struct NotesList: View {
    @EnvironmentObject private var notes: NotesStore
    var items: [DistractionNote]
    var limit: Int? = nil
    var light = false  // white text for the dark break screen

    var body: some View {
        let shown = limit.map { Array(items.prefix($0)) } ?? items
        VStack(alignment: .leading, spacing: 6) {
            ForEach(shown) { note in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Button { notes.toggle(note) } label: {
                        Image(systemName: note.done ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(note.done ? Phase.shortBreak.color : (light ? Color.white.opacity(0.6) : .secondary))
                    }
                    .buttonStyle(.plain)
                    .help(note.done ? "Mark as not done" : "Mark as done")

                    Text(note.text)
                        .strikethrough(note.done)
                        .foregroundStyle(light ? Color.white.opacity(note.done ? 0.4 : 0.85)
                                               : (note.done ? Color.secondary : Color.primary))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if !light {
                        Button { notes.delete(note) } label: {
                            Image(systemName: "xmark").font(.caption2).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Delete")
                    }
                }
            }
            if let limit, items.count > limit {
                Text("+\(items.count - limit) more in Settings → Notes")
                    .font(.caption)
                    .foregroundStyle(light ? Color.white.opacity(0.4) : .secondary)
            }
        }
    }
}

// MARK: - Settings tab

struct NotesSettingsView: View {
    @EnvironmentObject private var notes: NotesStore
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                if notes.open.isEmpty {
                    Text("Nothing parked. When a stray thought pops up during focus, press \(captureHint) and jot it down here instead of acting on it.")
                        .foregroundStyle(.secondary)
                } else {
                    NotesList(items: notes.open)
                }
                HStack {
                    Button("Jot Down a Thought…") { AppState.shared.notepad.showCapture() }
                    Spacer()
                    Button("Copy All") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(notes.plainText, forType: .string)
                    }
                    .disabled(notes.open.isEmpty)
                }
            } header: {
                Text("Parked thoughts")
            } footer: {
                Text("Notes stay hidden during focus (only a count is shown) and come back on your breaks, so you can deal with them then.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !notes.completed.isEmpty {
                Section("Done") {
                    NotesList(items: notes.completed)
                    Button("Clear Completed", role: .destructive) { notes.clearCompleted() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var captureHint: String {
        settings.shortcuts[HotKeyAction.capture.rawValue]?.display ?? "the notepad shortcut"
    }
}
