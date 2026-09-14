import SwiftUI

/// The menu bar dropdown: what's being watched, and what state each one is in.
struct MenuContent: View {
    let store: WatchStore
    let watcher: AppWatcher

    var body: some View {
        // Builds go out ad-hoc signed, so there's no other way to tell which one someone is running.
        Text(versionLabel)
        Divider()

        if store.apps.isEmpty {
            Text("No apps watched yet")
        } else {
            ForEach(store.apps) { app in
                // Status lines, not commands. The one app that needs a decision is the one
                // Watchdog has stopped retrying.
                if case .gaveUp = watcher.status(for: app) {
                    Button {
                        watcher.retryNow(app)
                    } label: {
                        Label("\(app.name) — gave up, retry?", systemImage: symbol(for: app))
                    }
                } else {
                    Label(label(for: app), systemImage: symbol(for: app))
                }
            }
        }

        Divider()

        SettingsLink {
            Text("Settings…")
        }
        .keyboardShortcut(",")

        Divider()

        Button("Quit Watchdog") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var versionLabel: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Watchdog \(version) (\(build))"
    }

    private func label(for app: WatchedApp) -> String {
        "\(app.name) — \(watcher.statusText(for: app))"
    }

    private func symbol(for app: WatchedApp) -> String {
        switch watcher.status(for: app) {
        case .running: "checkmark.circle.fill"
        case .launching: "arrow.triangle.2.circlepath"
        case .waitingToRestart: "clock"
        case .gaveUp: "exclamationmark.triangle.fill"
        case .notRunning: "circle"
        case .disabled: "pause.circle"
        }
    }
}
