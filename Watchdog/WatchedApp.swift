import AppKit

/// One app Watchdog is responsible for keeping running.
///
/// Identity is the bundle identifier, not a path or a PID: PIDs are recycled and tell us nothing
/// about a relaunch, and an app can move on disk between launches.
struct WatchedApp: Identifiable, Codable, Hashable {
    var bundleIdentifier: String
    var name: String
    /// Where the app was when it was added. Only a fallback — we resolve by bundle id at launch time.
    var lastKnownPath: String
    var isEnabled: Bool = true

    var id: String { bundleIdentifier }

    /// The app's current location, preferring Launch Services over the remembered path.
    var resolvedURL: URL {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
            ?? URL(fileURLWithPath: lastKnownPath)
    }

    var icon: NSImage {
        NSWorkspace.shared.icon(forFile: resolvedURL.path)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
        name = try container.decode(String.self, forKey: .name)
        lastKnownPath = try container.decode(String.self, forKey: .lastKnownPath)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }

    init?(applicationAt url: URL) {
        guard let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier else { return nil }
        self.bundleIdentifier = identifier
        self.name = FileManager.default.displayName(atPath: url.path)
        self.lastKnownPath = url.path
    }
}
