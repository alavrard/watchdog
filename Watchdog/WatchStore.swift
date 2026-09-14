import Foundation
import Observation
import OSLog

/// The persisted watch list. Small enough to live in UserDefaults as JSON.
@Observable
final class WatchStore {
    private static let defaultsKey = "watchedApps"

    private(set) var apps: [WatchedApp] = []

    init() {
        load()
    }

    // MARK: - Mutations

    enum AddError: LocalizedError {
        case notAnApplication
        case alreadyWatched(String)
        case isWatchdogItself

        var errorDescription: String? {
            switch self {
            case .notAnApplication: "That doesn't look like an application bundle."
            case .alreadyWatched(let name): "\(name) is already being watched."
            case .isWatchdogItself: "Watchdog can't watch itself."
            }
        }
    }

    @discardableResult
    func add(applicationAt url: URL) throws -> WatchedApp {
        guard let app = WatchedApp(applicationAt: url) else { throw AddError.notAnApplication }
        guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { throw AddError.isWatchdogItself }
        guard !apps.contains(where: { $0.bundleIdentifier == app.bundleIdentifier }) else {
            throw AddError.alreadyWatched(app.name)
        }
        apps.append(app)
        apps.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        save()
        return app
    }

    func remove(_ app: WatchedApp) {
        apps.removeAll { $0.bundleIdentifier == app.bundleIdentifier }
        save()
    }

    func remove(ids: Set<WatchedApp.ID>) {
        apps.removeAll { ids.contains($0.id) }
        save()
    }

    func setEnabled(_ isEnabled: Bool, for app: WatchedApp) {
        update(app) { $0.isEnabled = isEnabled }
    }

    func app(withBundleIdentifier identifier: String) -> WatchedApp? {
        apps.first { $0.bundleIdentifier == identifier }
    }

    private func update(_ app: WatchedApp, _ change: (inout WatchedApp) -> Void) {
        guard let index = apps.firstIndex(where: { $0.bundleIdentifier == app.bundleIdentifier }) else { return }
        change(&apps[index])
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey) else {
            Log.watcher.info("no saved watch list")
            return
        }
        do {
            apps = try JSONDecoder().decode([WatchedApp].self, from: data)
            Log.watcher.info("loaded \(self.apps.count) app(s) from \(data.count) bytes")
        } catch {
            Log.watcher.error("watch list is unreadable (\(data.count) bytes): \(error)")
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(apps) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}
