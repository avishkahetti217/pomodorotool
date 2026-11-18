# Pomodoro

A native macOS menu bar Pomodoro timer (SwiftUI, macOS 13+).

## Features
- **Menu bar countdown** for focus sessions and breaks (icon changes per phase; pause icon when paused)
- **Floating widget** (optional, Settings → Display): always-on-top card with countdown, progress bar and controls. Drag it anywhere (position is remembered), snap it to a corner, and adjust its opacity. Choose Menu bar, Floating widget, or Both.
- **Configurable durations**: focus, short break, long break, and how many sessions before a long break (default 4)
- **Sound + notification** at the end of every session (14 system sounds, preview, optional sound after breaks)
- **Daily tracking**: pomodoros and focus minutes per day, 14-day chart, 7-day total, streak
- **Focus blocking (optional)**: during a running focus session, hide or quit apps on a block list, or everything not on an allow list. Finder and System Settings are never blocked.
- Auto-start breaks / next session, launch at login, `Space` to start/pause in the popover

## Build & run
Requires only the Xcode Command Line Tools (Swift 5.9+).

```bash
./build.sh            # builds build/Pomodoro.app
./build.sh --install  # also copies to /Applications (or ~/Applications if you're not an admin) and launches it
```

On first launch, macOS asks for notification permission. Click **Allow**.
If you missed it: System Settings → Notifications → Pomodoro.

## Project layout
| File | Purpose |
| --- | --- |
| `PomodoroApp.swift` | App entry, menu bar item, shared state |
| `PomodoroTimer.swift` | Focus/break state machine (end-date based, survives sleep) |
| `AppSettings.swift` | Preferences persisted in UserDefaults |
| `StatsStore.swift` | Per-day pomodoro counts |
| `Notifier.swift` | Notifications and sounds |
| `AppBlocker.swift` | Focus-time app blocking via NSWorkspace |
| `MenuContentView.swift` | Menu bar popover UI |
| `SettingsView.swift` | Settings window (Timer, Focus Blocking, Statistics tabs) |

## Notes
- The app is ad-hoc signed for local use. To give it to other Macs you'd need a Developer ID signature and notarization.
- Blocking is "soft": it hides or quits apps as they're activated. It can't block websites inside a browser. For that, add the browser itself to the block list.
