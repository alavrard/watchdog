import SwiftUI
import UniformTypeIdentifiers

/// Manages the watch list: add apps, pause them, remove them.
struct SettingsView: View {
    let store: WatchStore
    let watcher: AppWatcher

    @State private var selection: Set<WatchedApp.ID> = []
    @State private var loginState = LoginItem.state
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Launch Watchdog at login", isOn: Binding(
                get: { loginState != .off },
                set: { setLaunchAtLogin($0) }
            ))

            if loginState == .awaitingApproval {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Watchdog is switched off in Login Items. Only System Settings can turn it back on.")
                        .font(.callout)
                    Button("Open Login Items", action: LoginItem.openSystemSettings)
                        .controlSize(.small)
                }
            }

            Text("Watched apps are started hidden when Watchdog launches, and restarted 30 seconds after they stop.")
                .font(.callout)
                .foregroundStyle(.secondary)

            appList

            HStack {
                Button("Add App…", action: addApps)
                Button("Remove", action: removeSelection)
                    .disabled(selection.isEmpty)
                Spacer()
                Text("or drag apps from Finder")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(20)
        .frame(width: 560, height: 420)
        .onAppear {
            loginState = LoginItem.state
            bringToFront()
        }
        // Approving in System Settings happens outside the app, so re-read the real state whenever
        // we come back to the front rather than trusting what we last stored.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            loginState = LoginItem.state
        }
        .alert("Couldn't do that", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var appList: some View {
        List(selection: $selection) {
            ForEach(store.apps) { app in
                row(for: app).tag(app.id)
            }
        }
        .border(.separator)
        .dropDestination(for: URL.self) { urls, _ in
            add(urls)
            return true
        }
        .overlay {
            if store.apps.isEmpty {
                ContentUnavailableView(
                    "No apps watched",
                    systemImage: "square.dashed",
                    description: Text("Add the apps you never want to find closed.")
                )
            }
        }
    }

    private func row(for app: WatchedApp) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: app.icon)
                .resizable()
                .frame(width: 28, height: 28)
                .opacity(app.isEnabled ? 1 : 0.5)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                Text(watcher.statusText(for: app))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            // A paused app is unattended; say so with the whole row, not just the checkbox.
            .opacity(app.isEnabled ? 1 : 0.5)

            Spacer()

            Toggle("Keep running", isOn: Binding(
                get: { app.isEnabled },
                set: {
                    store.setEnabled($0, for: app)
                    watcher.refresh()
                }
            ))
            .toggleStyle(.checkbox)
            .help("Watchdog restarts this app whenever it stops. Turn this off to leave the app alone — it won't quit it.")
        }
        .padding(.vertical, 4)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.setEnabled(enabled)
        } catch {
            errorMessage = error.localizedDescription
        }
        loginState = LoginItem.state
    }

    /// Bring the Settings window forward. A menu bar app is an `.accessory` app, so nothing does
    /// this for us: macOS never treats it as the app you're "in", and the cooperative
    /// `NSApp.activate()` quietly does nothing unless whatever is frontmost yields first — which it
    /// has no reason to. The dismissing menu also hands focus straight back, so this has to happen
    /// after the current runloop turn rather than during `onAppear`.
    private func bringToFront() {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows where window.isVisible && window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }
        }
    }

    // MARK: - Adding and removing

    private func addApps() {
        NSApp.activate(ignoringOtherApps: true)   // ...or the open panel lands behind too
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Watch"
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    private func add(_ urls: [URL]) {
        for url in urls where url.pathExtension == "app" {
            do {
                try store.add(applicationAt: url)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        watcher.refresh()
    }

    private func removeSelection() {
        store.remove(ids: selection)
        selection.removeAll()
        watcher.refresh()
    }
}
