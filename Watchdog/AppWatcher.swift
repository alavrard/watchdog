import AppKit
import Observation
import OSLog

enum Log {
    static let watcher = Logger(subsystem: "org.lavrard.Watchdog", category: "watcher")
}

/// Watches the apps in the store and restarts them when they stop running.
///
/// Detection is push-based: `NSWorkspace` posts a termination notification for *every* app on the
/// system, whatever killed it, so there's no polling of PIDs. A slow reconciliation sweep runs as a
/// backstop in case a notification is ever missed, and is also what launches everything at startup.
@Observable
final class AppWatcher {
    enum Status: Equatable {
        case running
        case launching
        /// Counting down to try number `attempt`.
        case waitingToRestart(until: Date, attempt: Int)
        /// Stopped again and again; not retrying until asked.
        case gaveUp
        case notRunning
        case disabled
    }

    /// Per-app state that only matters while Watchdog is running, so it isn't persisted.
    private struct Runtime {
        var status: Status = .notRunning
        /// Which try of the current failing streak is next. 0 while the app is healthy.
        var attempt = 0
        /// When the process actually started — read from the running app, not from when we
        /// happened to notice it, so adopting an app that's been up for hours doesn't look like a
        /// fresh start that immediately died.
        var startedAt: Date?
        var restartTask: Task<Void, Never>?
    }

    /// Seconds to wait before every restart, first or last.
    private let restartDelay: TimeInterval = 30
    /// An app that survives this long has proven itself; its failure streak resets.
    private let healthyAfter: TimeInterval = 30
    private let maxAttempts = 3
    private let reconcileInterval: TimeInterval = 30

    private let store: WatchStore
    private var runtime: [WatchedApp.ID: Runtime] = [:]
    private var observers: [NSObjectProtocol] = []
    private var runningAppsObservation: NSKeyValueObservation?
    private var pendingReconcile: Task<Void, Never>?
    private var reconcileTask: Task<Void, Never>?
    private var sessionRecoveryTask: Task<Void, Never>?
    /// Bumped every second while something is counting down, purely so the UI redraws.
    private var tick = 0
    private var tickTask: Task<Void, Never>?
    /// macOS quits every app at logout and shutdown. Relaunching them there would fight the system
    /// and can stall the shutdown, so all restarts stop once we know the session is ending.
    private var isSessionEnding = false

    init(store: WatchStore) {
        self.store = store
    }

    // MARK: - Lifecycle

    func start() {
        Log.watcher.info("watcher starting with \(self.store.apps.count) app(s)")
        let center = NSWorkspace.shared.notificationCenter

        observers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let identifier = note.runningApplication?.bundleIdentifier else { return }
            MainActor.assumeIsolated { self?.appDidTerminate(identifier) }
        })

        observers.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let running = note.runningApplication, let identifier = running.bundleIdentifier else { return }
            MainActor.assumeIsolated { self?.appDidLaunch(identifier, startedAt: running.launchDate) }
        })

        observers.append(center.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.endSession() }
        })

        // The two notifications above are never posted for `LSUIElement` apps — which is most of
        // what anyone watches, sync clients and password-manager agents included — so on their own
        // they'd leave exactly the wrong apps to be noticed by the 30s sweep. `runningApplications` is
        // KVO-compliant and does cover agent apps, so any change to it re-runs the sweep at once.
        runningAppsObservation = NSWorkspace.shared.observe(\.runningApplications) { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.reconcileSoon() }
            }
        }

        startReconciling()
    }

    /// Every app on the system launching or quitting lands here, so collapse a burst into one sweep.
    private func reconcileSoon() {
        pendingReconcile?.cancel()
        pendingReconcile = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.reconcile()
        }
    }

    private func startReconciling() {
        reconcileTask?.cancel()
        reconcileTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                self.reconcile()
                try? await Task.sleep(for: .seconds(self.reconcileInterval))
            }
        }
    }

    /// Stop restarting anything — the machine is logging out or shutting down.
    ///
    /// A logout can still be cancelled (another app refuses to quit), and macOS posts nothing to
    /// say so. If we're still alive a couple of minutes later the shutdown clearly didn't happen,
    /// so resume rather than staying dormant until Watchdog is restarted by hand.
    private func endSession() {
        guard !isSessionEnding else { return }
        isSessionEnding = true
        Log.watcher.info("session ending — restarts suspended")
        reconcileTask?.cancel()
        reconcileTask = nil
        for id in runtime.keys {
            runtime[id]?.restartTask?.cancel()
            runtime[id]?.restartTask = nil
        }

        sessionRecoveryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled, let self, self.isSessionEnding else { return }
            self.isSessionEnding = false
            Log.watcher.info("still running after 120s — logout was cancelled, resuming")
            self.startReconciling()
        }
    }

    // MARK: - Status, for the UI

    func status(for app: WatchedApp) -> Status {
        guard app.isEnabled else { return .disabled }
        if let status = runtime[app.id]?.status { return status }
        // Just added, and no sweep has run yet — ask the system rather than claiming it's stopped.
        return isRunning(app) ? .running : .notRunning
    }

    /// The one-line description shown under an app. Reads `tick` so a countdown redraws each second.
    func statusText(for app: WatchedApp) -> String {
        _ = tick
        return switch status(for: app) {
        case .running: "Running"
        case .launching: "Starting…"
        case .waitingToRestart(let until, let attempt):
            countdownText(until: until, attempt: attempt)
        case .gaveUp: "Gave up after \(maxAttempts) tries"
        case .notRunning: "Not running"
        case .disabled: "Paused"
        }
    }

    private func countdownText(until: Date, attempt: Int) -> String {
        let seconds = max(0, Int(until.timeIntervalSinceNow.rounded()))
        let base = seconds == 1 ? "Restarting in 1 second…" : "Restarting in \(seconds) seconds…"
        guard attempt > 1 else { return base }
        return "\(base) (\(ordinal(attempt)) try)"
    }

    private func ordinal(_ n: Int) -> String {
        switch n {
        case 1: "1st"
        case 2: "2nd"
        case 3: "3rd"
        default: "\(n)th"
        }
    }

    /// What the menu bar glyph should say about the whole list. Trouble outranks everything else:
    /// one app given up on matters more than nine apps running happily.
    var menuBarStatus: MenuBarIcon.Status {
        guard !store.apps.isEmpty else { return .empty }
        var anyWatched = false
        var working = false
        for app in store.apps {
            switch status(for: app) {
            case .disabled:
                continue
            case .gaveUp:
                return .gaveUp
            case .waitingToRestart, .launching, .notRunning:
                anyWatched = true
                working = true
            case .running:
                anyWatched = true
            }
        }
        guard anyWatched else { return .paused }
        return working ? .working : .allRunning
    }

    private func isRunning(_ app: WatchedApp) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == app.bundleIdentifier }
    }

    /// Pick up a change to the watch list right away rather than waiting for the next sweep.
    func refresh() {
        reconcile()
    }

    /// Clear a give-up and try again now.
    func retryNow(_ app: WatchedApp) {
        runtime[app.id]?.restartTask?.cancel()
        runtime[app.id, default: Runtime()].attempt = 0
        guard !isRunning(app) else { return refresh() }
        // No notification: you just asked for this, you don't need telling.
        Task { await launch(app, notifying: false) }
    }

    // MARK: - Reacting to the world

    private func appDidTerminate(_ bundleIdentifier: WatchedApp.ID) {
        guard let app = store.app(withBundleIdentifier: bundleIdentifier) else { return }
        handleTermination(of: app)
    }

    private func handleTermination(of app: WatchedApp) {
        guard !isSessionEnding, app.isEnabled else { return }
        // The notification and the sweep can both report the same death; whichever gets here first
        // owns it. (`.launching` isn't in this list: an app that dies mid-launch is a real failure.)
        switch runtime[app.id]?.status {
        case .waitingToRestart, .gaveUp: return
        default: break
        }

        var state = runtime[app.id] ?? Runtime()
        state.restartTask?.cancel()
        state.restartTask = nil
        // Dying seconds after starting means it's failing on launch, and a streak of those is what
        // the try limit is for. Anything that ran longer than that — or that we have no start time
        // for, because it was already up before we were — starts a fresh streak.
        let diedYoung = state.startedAt.map { Date().timeIntervalSince($0) < healthyAfter } ?? false
        state.attempt = diedYoung ? state.attempt + 1 : 1
        state.startedAt = nil
        runtime[app.id] = state

        scheduleRestart(of: app)
    }

    private func appDidLaunch(_ bundleIdentifier: WatchedApp.ID, startedAt: Date?) {
        guard let app = store.app(withBundleIdentifier: bundleIdentifier) else { return }
        var state = runtime[app.id] ?? Runtime()
        // It's back — whether we started it or the user did — so drop any pending restart.
        state.restartTask?.cancel()
        state.restartTask = nil
        state.status = .running
        state.startedAt = startedAt ?? Date()
        runtime[app.id] = state
        updateTicker()
    }

    // MARK: - Restarting

    private func scheduleRestart(of app: WatchedApp) {
        guard !isSessionEnding else { return }
        var state = runtime[app.id] ?? Runtime()

        guard state.attempt <= maxAttempts else {
            state.status = .gaveUp
            state.restartTask = nil
            runtime[app.id] = state
            updateTicker()
            Log.watcher.error("giving up on \(app.name, privacy: .public) after \(self.maxAttempts) tries")
            Notifier.post(
                title: "\(app.name) keeps quitting",
                body: "Watchdog restarted it \(maxAttempts) times and it stopped again each time, so it gave up. Use Retry in the menu once it's fixed."
            )
            return
        }

        let attempt = state.attempt
        Log.watcher.info("scheduling restart of \(app.name, privacy: .public) in \(self.restartDelay)s (try \(attempt))")
        state.status = .waitingToRestart(until: Date().addingTimeInterval(restartDelay), attempt: attempt)
        state.restartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.restartDelay ?? 30))
            guard !Task.isCancelled else { return }
            await self?.launch(app)
        }
        runtime[app.id] = state
        updateTicker()
    }

    private func launch(_ app: WatchedApp, notifying: Bool = true) async {
        guard !isSessionEnding else { return }
        // Re-read the store: the app may have been removed or disabled while we were waiting.
        guard let app = store.app(withBundleIdentifier: app.bundleIdentifier), app.isEnabled else { return }
        guard !isRunning(app) else { return refresh() }   // beaten to it; don't claim a restart

        runtime[app.id, default: Runtime()].status = .launching
        // Provisional: the launch notification replaces this with the process's real start time.
        runtime[app.id]?.startedAt = Date()
        updateTicker()

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false     // don't steal focus from whatever you're doing
        configuration.hides = true          // ...and don't put its windows in front of you either
        configuration.addsToRecentItems = false

        do {
            _ = try await NSWorkspace.shared.openApplication(at: app.resolvedURL, configuration: configuration)
            runtime[app.id]?.status = .running
            Log.watcher.info("launched \(app.name, privacy: .public)")
            if notifying {
                Notifier.post(title: "Restarted \(app.name)", body: "It had stopped running.")
            }
        } catch {
            Log.watcher.error("failed to launch \(app.name, privacy: .public): \(error.localizedDescription)")
            runtime[app.id, default: Runtime()].attempt += 1
            scheduleRestart(of: app)
        }
    }

    /// Keep a one-second heartbeat running for as long as any countdown is on screen.
    private func updateTicker() {
        let isCountingDown = runtime.values.contains {
            if case .waitingToRestart = $0.status { return true }
            return false
        }
        guard isCountingDown else {
            tickTask?.cancel()
            tickTask = nil
            return
        }
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.tick &+= 1
            }
        }
    }

    // MARK: - Backstop

    /// Bring reality and intent back in line: launch anything that should be running and isn't,
    /// and forgive apps that have been up long enough to prove they're healthy.
    private func reconcile() {
        guard !isSessionEnding else { return }
        // Debug, not info: this now runs on every app launch or quit anywhere on the system.
        Log.watcher.debug("reconcile: \(self.store.apps.count) watched")
        let running = Dictionary(
            NSWorkspace.shared.runningApplications.compactMap { app in
                app.bundleIdentifier.map { ($0, app) }
            },
            uniquingKeysWith: { first, _ in first }
        )

        for app in store.apps {
            guard app.isEnabled else {
                runtime[app.id]?.restartTask?.cancel()
                runtime[app.id] = Runtime(status: .disabled)
                continue
            }

            if let process = running[app.bundleIdentifier] {
                var state = runtime[app.id] ?? Runtime()
                // It's up, so nothing is owed — it may have been relaunched by hand while we were
                // counting down, and agent apps don't post the launch notification that would have
                // told us so.
                state.restartTask?.cancel()
                state.restartTask = nil
                state.status = .running
                if state.startedAt == nil { state.startedAt = process.launchDate ?? Date() }
                if let started = state.startedAt, Date().timeIntervalSince(started) > healthyAfter {
                    state.attempt = 0   // it survived; stop holding the past against it
                }
                runtime[app.id] = state
                continue
            }

            switch status(for: app) {
            case .waitingToRestart, .launching, .gaveUp:
                continue    // a restart is already in flight, or we've stopped trying
            case .running:
                // We thought it was up, so we missed its termination notification.
                handleTermination(of: app)
            case .notRunning, .disabled:
                // Startup, or an app that was just added: bring it up now rather than after a wait,
                // and quietly — nothing was restarted, so there's nothing to report.
                runtime[app.id, default: Runtime()].status = .notRunning
                Task { await launch(app, notifying: false) }
            }
        }
        updateTicker()
    }
}

private extension Notification {
    var runningApplication: NSRunningApplication? {
        userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    }
}
