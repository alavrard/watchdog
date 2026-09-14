# Watchdog

A small macOS menu bar utility that keeps a list of apps running. It launches them at login and
restarts them whenever they stop — whether they crashed or you closed them by accident with Cmd-Q.

It exists for the apps you never really want to find closed: a sync client, a password manager, a
VPN agent, a backup tool. The kind of app you only notice has been dead for three days when you go
looking for something it should have been doing.

## What it looks like

Watchdog has no Dock icon and no main window. It's a paw in the menu bar, badged with how things
are going: a tick when everything is running, an ellipsis while something is starting or counting
down, a cross when it has given up on an app, a pause when everything is paused.

The dropdown lists each watched app and its state — `Running`, `Starting…`,
`Restarting in 22 seconds… (2nd try)`, `Gave up after 3 tries`, `Paused`. Those rows are status,
not buttons; the only clickable one is an app Watchdog has stopped retrying, which offers a retry.

Settings is the watch list: drag apps in from Finder or use **Add App…**, uncheck one to leave it
alone for a while, select and **Remove** to stop watching it.

## How it behaves

- **Restarts wait 30 seconds, and there are three of them.** Crash or deliberate quit, the handling
  is the same: wait 30 seconds, launch. If the app dies again within 30 seconds of starting, that
  counts as the next try in the streak. After three tries Watchdog gives up and tells you. An app
  that stays up longer than 30 seconds has proven itself and its streak resets, so an app you quit
  once a day always gets the same treatment.
- **Restarts are invisible.** Every launch is hidden and doesn't take focus — the same as `open -j`,
  or the Hide checkbox next to a login item. A restart should never interrupt what you're doing.
- **Only real restarts notify you.** Launching apps at login, launching one you just added, and
  retrying by hand are all silent. Otherwise logging in would fire one notification per watched app.
- **Nothing is relaunched at logout or shutdown.** macOS quits everything then; fighting that can
  stall the shutdown, so Watchdog stops restarting as soon as it knows the session is ending.
- **There's no escape hatch.** A watched app always comes back. To stop that, pause it or remove it.

Detection is push-based, not polling: Watchdog observes `NSWorkspace.runningApplications`, so it
notices a death within moments — including for background/agent apps (`LSUIElement`), which macOS
never posts launch or terminate notifications for, and which happen to be most of what anyone wants
watched. A 30-second reconciliation sweep is the backstop, and is also what launches everything at
startup.

Apps are tracked by **bundle identifier**, not by path or PID. PIDs get recycled and say nothing
about whether an app came back, and apps move on disk; the recorded path is only a fallback.

### Watchdog keeps itself alive too

"Launch Watchdog at login" doesn't register a login item — it registers a launchd agent
(`SMAppService.agent`) with `KeepAlive`/`SuccessfulExit: false`. A login item would only start
Watchdog once at login; if Watchdog itself crashed, everything it was watching would quietly stop
being watched with nothing to say so. With the agent, launchd brings it back after a crash (about
10 seconds later — launchd throttles respawns) and leaves it quit when you quit it on purpose.

macOS shows an "added items that can run in the background" notice when you turn this on. That's
macOS informing you, not asking; System Settings → Login Items is where you'd turn it off. If you
do turn it off there, re-enabling has to happen in System Settings — Watchdog says so and gives you
a button through to the right pane.

## Requirements

macOS 14 (Sonoma) or later. To build: Xcode with a macOS 14 SDK or newer. No dependencies, no
package manager, one target.

## Building

```bash
git clone https://github.com/alavrard/watchdog.git
cd watchdog
xcodebuild -project Watchdog.xcodeproj -scheme Watchdog -configuration Release build
open ~/Library/Developer/Xcode/DerivedData/Watchdog-*/Build/Products/Release/
```

Then drag `Watchdog.app` to `/Applications`. Or just open `Watchdog.xcodeproj` and hit Run.

Builds here are ad-hoc signed (hardened runtime, no entitlements). That's enough for macOS to
register the launchd agent, but **not** enough for Gatekeeper: a build you didn't compile yourself
gets a malware warning, and you have to allow it once under System Settings → Privacy & Security →
**Open Anyway**. Silencing that needs a paid Developer ID and notarisation.

## Permissions and privacy

- **Not sandboxed.** A sandboxed app can't launch arbitrary third-party apps, which is the entire
  job. There are no entitlements in the shipped build.
- **No network access.** Watchdog never talks to anything. There is no telemetry, no update check.
- **The watch list is stored locally** as JSON in `UserDefaults` under
  `org.lavrard.Watchdog`, and holds only bundle identifiers, display names and paths.
- It asks for **notification** permission, to tell you about restarts. Deny it and everything else
  still works.

## Troubleshooting

Watchdog logs to the unified log under its own subsystem:

```bash
/usr/bin/log show --last 5m --info --predicate 'subsystem == "org.lavrard.Watchdog"' --style compact
/usr/bin/log stream --predicate 'subsystem == "org.lavrard.Watchdog"'
```

Spell out `/usr/bin/log` — in zsh, `log` is a builtin and a bare `log show` silently does nothing.

Check whether the launchd agent is registered and enabled:

```bash
launchctl print-disabled gui/$UID | grep Watchdog
launchctl print gui/$UID/org.lavrard.Watchdog
```

## Layout

| Path | What's in it |
| --- | --- |
| `Watchdog/WatchdogApp.swift` | `@main` entry point, shared services, app delegate |
| `Watchdog/AppWatcher.swift` | The engine: detection, restart scheduling, give-up logic |
| `Watchdog/WatchedApp.swift`, `WatchStore.swift` | The model and its persistence |
| `Watchdog/MenuContent.swift`, `SettingsView.swift` | The dropdown and the settings window |
| `Watchdog/MenuBarIcon.swift` | The menu bar glyph, composed at runtime |
| `Watchdog/LoginItem.swift`, `Notifier.swift` | `SMAppService` registration and notifications |
| `LaunchAgents/org.lavrard.Watchdog.plist` | The launchd job, copied into the bundle at build time |

The Xcode project uses synchronized folders, so any `.swift` file added under `Watchdog/` joins the
target automatically — `project.pbxproj` never needs hand-editing.

`CLAUDE.md` in the repo root documents the design decisions and the several ways this app can be
broken by an innocent-looking change; worth reading before touching `AppWatcher`.
