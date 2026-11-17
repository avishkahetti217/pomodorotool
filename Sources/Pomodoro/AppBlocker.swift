import AppKit
import Combine

/// While a focus session runs, hides or quits apps according to the user's block/allow list.
/// Uses only public NSWorkspace APIs, so no special permissions are required.
@MainActor
final class AppBlocker {
    /// Apps that are never touched, so the Mac stays usable.
    static let alwaysAllowed: Set<String> = [
        "com.apple.finder",
        "com.apple.systempreferences",
        "com.apple.loginwindow",
        "com.apple.dock",
    ]

    private let settings: AppSettings
    private let notifier: Notifier
    private(set) var isFocusActive = false
    private var observer: NSObjectProtocol?
    private var lastWarned: [String: Date] = [:]
    private var settingsSubscription: AnyCancellable?

    init(settings: AppSettings, notifier: Notifier) {
        self.settings = settings
        self.notifier = notifier
        // Re-apply rules if the user edits them mid-session.
        settingsSubscription = settings.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.sweep() }
        }
    }

    func setFocusActive(_ active: Bool) {
        guard active != isFocusActive else { return }
        isFocusActive = active
        if active {
            observer = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                MainActor.assumeIsolated { self?.enforce(app) }
            }
            sweep()
        } else if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            self.observer = nil
        }
    }

    private var isEnforcing: Bool { isFocusActive && settings.blockingEnabled }

    func shouldBlock(_ app: NSRunningApplication) -> Bool {
        guard app.activationPolicy == .regular,
              let id = app.bundleIdentifier,
              id != Bundle.main.bundleIdentifier,
              !Self.alwaysAllowed.contains(id) else { return false }
        switch settings.blockMode {
        case .blocklist: return settings.blockedApps.contains { $0.bundleID == id }
        case .allowlist: return !settings.allowedApps.contains { $0.bundleID == id }
        }
    }

    /// Apply rules to apps already running when focus starts.
    /// In allow-list mode only the frontmost app is acted on, to avoid mass-quitting everything.
    private func sweep() {
        guard isEnforcing else { return }
        let apps: [NSRunningApplication]
        switch settings.blockMode {
        case .blocklist: apps = NSWorkspace.shared.runningApplications
        case .allowlist: apps = NSWorkspace.shared.frontmostApplication.map { [$0] } ?? []
        }
        apps.filter(shouldBlock).forEach { enforce($0) }
    }

    private func enforce(_ app: NSRunningApplication) {
        guard isEnforcing, shouldBlock(app) else { return }
        switch settings.blockAction {
        case .hide:
            app.hide()
            // Hiding can be ignored while the app is mid-activation; try once more.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.isEnforcing, app.isActive else { return }
                app.hide()
            }
        case .quit:
            app.terminate()
        }
        warn(about: app)
    }

    private func warn(about app: NSRunningApplication) {
        let id = app.bundleIdentifier ?? ""
        if let last = lastWarned[id], Date().timeIntervalSince(last) < 60 { return }
        lastWarned[id] = Date()
        let name = app.localizedName ?? "That app"
        let verb = settings.blockAction == .hide ? "hidden" : "closed"
        notifier.post(title: "\(name) is blocked during focus",
                      body: "It was \(verb). Stay on track, you've got this.",
                      identifier: "blocked-\(id)")
    }
}
