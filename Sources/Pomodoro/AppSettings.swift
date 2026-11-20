import Foundation

enum BlockMode: String, CaseIterable, Identifiable {
    case blocklist, allowlist
    var id: String { rawValue }
    var label: String {
        switch self {
        case .blocklist: return "Block selected apps"
        case .allowlist: return "Allow only selected apps"
        }
    }
}

enum BlockAction: String, CaseIterable, Identifiable {
    case hide, quit
    var id: String { rawValue }
    var label: String {
        switch self {
        case .hide: return "Hide the app"
        case .quit: return "Quit the app"
        }
    }
}

enum DisplayMode: String, CaseIterable, Identifiable {
    case menuBar, floating, both
    var id: String { rawValue }
    var label: String {
        switch self {
        case .menuBar: return "Menu bar"
        case .floating: return "Floating widget"
        case .both: return "Both"
        }
    }
    var showsMenuBar: Bool { self != .floating }
    var showsWidget: Bool { self != .menuBar }
}

enum WidgetSize: String, CaseIterable, Identifiable {
    case mini, compact, regular
    var id: String { rawValue }
    var label: String {
        switch self {
        case .mini: return "Mini"
        case .compact: return "Compact"
        case .regular: return "Regular"
        }
    }
}

struct ListedApp: Codable, Hashable, Identifiable {
    var bundleID: String
    var name: String
    var id: String { bundleID }
}

/// User preferences, persisted to UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    private enum Key {
        static let focus = "focusMinutes"
        static let shortBreak = "shortBreakMinutes"
        static let longBreak = "longBreakMinutes"
        static let sessions = "sessionsBeforeLongBreak"
        static let autoBreaks = "autoStartBreaks"
        static let autoFocus = "autoStartFocus"
        static let sound = "soundName"
        static let soundAfterBreaks = "soundAfterBreaks"
        static let blockingEnabled = "blockingEnabled"
        static let blockMode = "blockMode"
        static let blockAction = "blockAction"
        static let blockedApps = "blockedApps"
        static let allowedApps = "allowedApps"
        static let displayMode = "displayMode"
        static let widgetOpacity = "widgetOpacity"
        static let widgetSize = "widgetSize"
        static let celebrate = "celebrateSessions"
        static let breakTips = "showBreakTips"
    }

    @Published var displayMode: DisplayMode {
        didSet { defaults.set(displayMode.rawValue, forKey: Key.displayMode) }
    }
    @Published var celebrateSessions: Bool {
        didSet { defaults.set(celebrateSessions, forKey: Key.celebrate) }
    }
    @Published var showBreakTips: Bool {
        didSet { defaults.set(showBreakTips, forKey: Key.breakTips) }
    }
    @Published var widgetSize: WidgetSize {
        didSet { defaults.set(widgetSize.rawValue, forKey: Key.widgetSize) }
    }
    @Published var widgetOpacity: Double {
        didSet { defaults.set(widgetOpacity, forKey: Key.widgetOpacity) }
    }

    /// Bound to the menu bar item's visibility. If the user ⌘-drags the item out of
    /// the menu bar, fall back to the floating widget so the timer never disappears.
    var showsMenuBarItem: Bool {
        get { displayMode.showsMenuBar }
        set {
            if !newValue, displayMode.showsMenuBar { displayMode = .floating }
            if newValue, displayMode == .floating { displayMode = .both }
        }
    }

    @Published var focusMinutes: Int {
        didSet {
            let c = focusMinutes.clamped(1...180)
            if c != focusMinutes { focusMinutes = c; return }  // only reassign when out of range, avoids recursion
            defaults.set(focusMinutes, forKey: Key.focus)
        }
    }
    @Published var shortBreakMinutes: Int {
        didSet {
            let c = shortBreakMinutes.clamped(1...60)
            if c != shortBreakMinutes { shortBreakMinutes = c; return }  // only reassign when out of range, avoids recursion
            defaults.set(shortBreakMinutes, forKey: Key.shortBreak)
        }
    }
    @Published var longBreakMinutes: Int {
        didSet {
            let c = longBreakMinutes.clamped(1...120)
            if c != longBreakMinutes { longBreakMinutes = c; return }  // only reassign when out of range, avoids recursion
            defaults.set(longBreakMinutes, forKey: Key.longBreak)
        }
    }
    @Published var sessionsBeforeLongBreak: Int {
        didSet {
            let c = sessionsBeforeLongBreak.clamped(2...12)
            if c != sessionsBeforeLongBreak { sessionsBeforeLongBreak = c; return }  // only reassign when out of range, avoids recursion
            defaults.set(sessionsBeforeLongBreak, forKey: Key.sessions)
        }
    }
    @Published var autoStartBreaks: Bool {
        didSet { defaults.set(autoStartBreaks, forKey: Key.autoBreaks) }
    }
    @Published var autoStartFocus: Bool {
        didSet { defaults.set(autoStartFocus, forKey: Key.autoFocus) }
    }
    @Published var soundName: String {
        didSet { defaults.set(soundName, forKey: Key.sound) }
    }
    @Published var soundAfterBreaks: Bool {
        didSet { defaults.set(soundAfterBreaks, forKey: Key.soundAfterBreaks) }
    }
    @Published var blockingEnabled: Bool {
        didSet { defaults.set(blockingEnabled, forKey: Key.blockingEnabled) }
    }
    @Published var blockMode: BlockMode {
        didSet { defaults.set(blockMode.rawValue, forKey: Key.blockMode) }
    }
    @Published var blockAction: BlockAction {
        didSet { defaults.set(blockAction.rawValue, forKey: Key.blockAction) }
    }
    @Published var blockedApps: [ListedApp] {
        didSet { save(blockedApps, Key.blockedApps) }
    }
    @Published var allowedApps: [ListedApp] {
        didSet { save(allowedApps, Key.allowedApps) }
    }

    init() {
        defaults.register(defaults: [
            Key.focus: 25,
            Key.shortBreak: 5,
            Key.longBreak: 15,
            Key.sessions: 4,
            Key.autoBreaks: false,
            Key.autoFocus: false,
            Key.sound: "Glass",
            Key.soundAfterBreaks: true,
            Key.blockingEnabled: false,
            Key.blockMode: BlockMode.blocklist.rawValue,
            Key.blockAction: BlockAction.hide.rawValue,
            Key.displayMode: DisplayMode.menuBar.rawValue,
            Key.widgetOpacity: 1.0,
            Key.widgetSize: WidgetSize.compact.rawValue,
            Key.celebrate: true,
            Key.breakTips: true,
        ])
        displayMode = DisplayMode(rawValue: defaults.string(forKey: Key.displayMode) ?? "") ?? .menuBar
        widgetOpacity = defaults.double(forKey: Key.widgetOpacity)
        celebrateSessions = defaults.bool(forKey: Key.celebrate)
        showBreakTips = defaults.bool(forKey: Key.breakTips)
        widgetSize = WidgetSize(rawValue: defaults.string(forKey: Key.widgetSize) ?? "") ?? .compact
        focusMinutes = defaults.integer(forKey: Key.focus)
        shortBreakMinutes = defaults.integer(forKey: Key.shortBreak)
        longBreakMinutes = defaults.integer(forKey: Key.longBreak)
        sessionsBeforeLongBreak = defaults.integer(forKey: Key.sessions)
        autoStartBreaks = defaults.bool(forKey: Key.autoBreaks)
        autoStartFocus = defaults.bool(forKey: Key.autoFocus)
        soundName = defaults.string(forKey: Key.sound) ?? "Glass"
        soundAfterBreaks = defaults.bool(forKey: Key.soundAfterBreaks)
        blockingEnabled = defaults.bool(forKey: Key.blockingEnabled)
        blockMode = BlockMode(rawValue: defaults.string(forKey: Key.blockMode) ?? "") ?? .blocklist
        blockAction = BlockAction(rawValue: defaults.string(forKey: Key.blockAction) ?? "") ?? .hide
        blockedApps = Self.load(Key.blockedApps, from: defaults)
        allowedApps = Self.load(Key.allowedApps, from: defaults)
    }

    func duration(for phase: Phase) -> TimeInterval {
        switch phase {
        case .focus: return TimeInterval(focusMinutes * 60)
        case .shortBreak: return TimeInterval(shortBreakMinutes * 60)
        case .longBreak: return TimeInterval(longBreakMinutes * 60)
        }
    }

    func minutes(for phase: Phase) -> Int {
        Int(duration(for: phase) / 60)
    }

    private func save(_ apps: [ListedApp], _ key: String) {
        defaults.set(try? JSONEncoder().encode(apps), forKey: key)
    }

    private static func load(_ key: String, from defaults: UserDefaults) -> [ListedApp] {
        guard let data = defaults.data(forKey: key),
              let apps = try? JSONDecoder().decode([ListedApp].self, from: data) else { return [] }
        return apps
    }
}

extension Comparable {
    func clamped(_ range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
