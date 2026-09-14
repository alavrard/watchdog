import SwiftUI
import OSLog

/// Shared, long-lived objects. A MenuBarExtra's content isn't built until the menu is opened, so
/// the watcher can't be started from a view — it's started from the app delegate instead.
@MainActor
final class AppServices {
    static let shared = AppServices()

    let store: WatchStore
    let watcher: AppWatcher

    private init() {
        store = WatchStore()
        watcher = AppWatcher(store: store)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            Log.watcher.info("app did finish launching")
            Notifier.requestAuthorization()
            Log.watcher.info("notification authorization requested")
            AppServices.shared.watcher.start()
        }
    }
}

@main
struct WatchdogApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    private var store: WatchStore { AppServices.shared.store }
    private var watcher: AppWatcher { AppServices.shared.watcher }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(store: store, watcher: watcher)
        } label: {
            Image(nsImage: MenuBarIcon.image(for: watcher.menuBarStatus))
                .accessibilityLabel("Watchdog")
        }

        Settings {
            SettingsView(store: store, watcher: watcher)
        }
    }
}
