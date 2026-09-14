import OSLog
import ServiceManagement

/// Registers Watchdog itself with launchd, so it's running before anything it watches — and comes
/// back if it crashes.
///
/// This is a launchd *agent* (`Contents/Library/LaunchAgents/org.lavrard.Watchdog.plist`), not a plain
/// login item. A login item only gets you launched once at login: if Watchdog itself crashed, every
/// app it was watching would quietly stop being watched, with nothing to say so. The agent plist
/// carries `KeepAlive`/`SuccessfulExit: false`, so launchd restarts Watchdog when it dies badly and
/// leaves it alone when you quit it deliberately.
enum LoginItem {
    /// Registration isn't quite a boolean. `register()` normally enables the job outright — the
    /// "added items that can run in the background" notification is macOS telling you, not asking
    /// you. But if the user has since switched Watchdog *off* in System Settings → Login Items,
    /// registering again lands in `requiresApproval`: registered, and not going to run, with only
    /// System Settings able to change that. Reporting that as plain "off" would make the switch
    /// flick back by itself with no explanation.
    enum State: Equatable {
        case off
        case on
        case awaitingApproval
    }

    private static let plistName = "org.lavrard.Watchdog.plist"
    private static var service: SMAppService { SMAppService.agent(plistName: plistName) }

    static var state: State {
        switch service.status {
        case .enabled: .on
        case .requiresApproval: .awaitingApproval
        default: .off
        }
    }

    static var isEnabled: Bool { state != .off }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            // Watchdog used to register as a plain login item. Leaving that behind would launch a
            // second copy at login, so clear it out on the way past.
            try? SMAppService.mainApp.unregister()
            try service.register()
        } else {
            try service.unregister()
        }
        Log.watcher.info("login item set to \(enabled) — now \(String(describing: state))")
    }

    /// Take the user to the switch they need to flip, rather than describing where it lives.
    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
