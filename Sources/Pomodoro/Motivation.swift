import Foundation

/// Short, screen-free break suggestions. Kept under ~40 characters so they fit the compact widget.
enum BreakIdeas {
    static let short = [
        "Stand up and stretch your back",
        "Refill your water glass",
        "Look out a window for 20 seconds",
        "Take five slow, deep breaths",
        "Roll your shoulders and neck",
        "Walk to the kitchen and back",
        "Leave the phone, rest your eyes",
        "Tidy one thing on your desk",
        "Shake out your hands and wrists",
        "Close your eyes for a minute",
    ]

    static let long = [
        "Phone down, step outside for a walk",
        "Get some fresh air and daylight",
        "Grab a healthy snack",
        "Stretch your whole body",
        "Chat with someone, not on a screen",
        "Make a cup of tea, slowly",
        "Walk around the block",
        "Do a few squats or a quick plank",
    ]

    private static var last: String?

    /// A random idea for the given break, never the same as the previous one.
    static func random(for phase: Phase) -> String? {
        let pool: [String]
        switch phase {
        case .focus: return nil
        case .shortBreak: pool = short
        case .longBreak: pool = long
        }
        let pick = pool.filter { $0 != last }.randomElement() ?? pool[0]
        last = pick
        return pick
    }
}

/// Everything the end-of-session reward card needs to show.
struct Celebration {
    let completedInCycle: Int
    let cycleLength: Int
    let todayCount: Int
    let isPersonalBest: Bool
    let nextPhase: Phase
    let nextMinutes: Int
    let tip: String?

    var isCycleComplete: Bool { nextPhase == .longBreak }

    var headline: String {
        if isCycleComplete { return "Full cycle complete!" }
        return ["Session complete!", "Nice focus!", "Well done!", "One more in the bag!"].randomElement()!
    }

    var progressText: String {
        Encouragement.cycleProgress(left: cycleLength - completedInCycle,
                                    nextPhase: nextPhase, nextMinutes: nextMinutes)
    }
}

enum Encouragement {
    static func cycleProgress(left: Int, nextPhase: Phase, nextMinutes: Int) -> String {
        if nextPhase == .longBreak || left <= 0 {
            return "Enjoy your \(nextMinutes)-min long break"
        }
        return left == 1 ? "Just 1 more session to a full cycle"
                         : "\(left) more sessions to a full cycle"
    }
}
