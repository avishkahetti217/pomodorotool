import Foundation

struct DayStats: Codable, Equatable {
    var pomodoros: Int = 0
    var focusSeconds: Double = 0
}

struct DayEntry: Identifiable {
    let date: Date
    let stats: DayStats
    var id: Date { date }
}

/// Tracks completed pomodoros per calendar day, persisted to UserDefaults.
@MainActor
final class StatsStore: ObservableObject {
    private static let storageKey = "dailyStats"
    private let defaults = UserDefaults.standard

    @Published private(set) var days: [String: DayStats]

    private static let keyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    init() {
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([String: DayStats].self, from: data) {
            days = decoded
        } else {
            days = [:]
        }
    }

    static func key(for date: Date) -> String {
        keyFormatter.string(from: date)
    }

    var today: DayStats {
        days[Self.key(for: Date())] ?? DayStats()
    }

    func recordPomodoro(focusSeconds: TimeInterval, on date: Date = Date()) {
        let key = Self.key(for: date)
        var entry = days[key] ?? DayStats()
        entry.pomodoros += 1
        entry.focusSeconds += focusSeconds
        days[key] = entry
        persist()
    }

    func resetToday() {
        days[Self.key(for: Date())] = nil
        persist()
    }

    /// The last `count` days, oldest first, including days with no sessions.
    func history(days count: Int) -> [DayEntry] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        return (0..<count).reversed().compactMap { offset in
            guard let date = cal.date(byAdding: .day, value: -offset, to: start) else { return nil }
            return DayEntry(date: date, stats: days[Self.key(for: date)] ?? DayStats())
        }
    }

    var totalPomodoros: Int {
        days.values.reduce(0) { $0 + $1.pomodoros }
    }

    /// Consecutive days (ending today, or yesterday if today has none yet) with at least one pomodoro.
    var currentStreak: Int {
        let cal = Calendar.current
        var date = cal.startOfDay(for: Date())
        if (days[Self.key(for: date)]?.pomodoros ?? 0) == 0 {
            date = cal.date(byAdding: .day, value: -1, to: date)!
        }
        var streak = 0
        while (days[Self.key(for: date)]?.pomodoros ?? 0) > 0 {
            streak += 1
            date = cal.date(byAdding: .day, value: -1, to: date)!
        }
        return streak
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(days), forKey: Self.storageKey)
    }
}
