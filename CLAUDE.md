# Watchdog

macOS SwiftUI app (`SDKROOT = macosx`, deployment target 26.5). Single target, no dependencies.

## Build & run

```bash
xcodebuild -project Watchdog.xcodeproj -scheme Watchdog -configuration Debug build
```

Run the built app:

```bash
open ~/Library/Developer/Xcode/DerivedData/Watchdog-*/Build/Products/Debug/Watchdog.app
```

Quieter output for checking whether it compiles:

```bash
xcodebuild -project Watchdog.xcodeproj -scheme Watchdog build 2>&1 | grep -E "error:|warning:|BUILD"
```

Note: `xcodebuild` insists on writing to `~/Library/Developer/Xcode/DerivedData` — it rejects a
`-derivedDataPath` pointed at a temp dir, so builds can't be redirected to a scratch location.

## Adding files

The project uses Xcode 16's synchronized folders (`objectVersion = 77`, one
`PBXFileSystemSynchronizedRootGroup` for `Watchdog/`). Creating a `.swift` file anywhere under
`Watchdog/` adds it to the target automatically — never hand-edit `project.pbxproj` to register
sources.

## Sending a build to someone else

Deployment target is **macOS 14.0** — keep it there unless there's a reason to move it. The Xcode
template started this at 26.5, which silently excludes everyone not on the newest macOS; nothing in
the code needs anything newer than Sonoma.

Release is ad-hoc signed with hardened runtime and no entitlements. Two settings keep it that way:
`CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO` (Xcode otherwise ships `com.apple.security.get-task-allow`
in *Release*, which lets anything attach a debugger to the app and makes notarisation fail) and
`ENABLE_HARDENED_RUNTIME = YES`. Verify before sending anything:

```bash
codesign -d --entitlements - --xml <app> | plutil -p -   # must be empty
codesign -dvvv <app> 2>&1 | grep flags                   # must say runtime
```

Package with `ditto -c -k --keepParent <app> Watchdog.zip` — a Finder zip or `zip -r` can mangle the
bundle. Ad-hoc signing is enough for `SMAppService` to register the launchd agent (verified), but it
is *not* enough for Gatekeeper: the recipient gets a malware warning and has to allow it once under
System Settings → Privacy & Security → Open Anyway. Silencing that needs a paid Developer ID plus
notarisation, and nothing else will do it.

## Layout

- `Watchdog/WatchdogApp.swift` — `@main` App entry point, `AppServices`, `AppDelegate`
- `Watchdog/AppWatcher.swift` — the engine
- `Watchdog/WatchedApp.swift` / `WatchStore.swift` — the model and its persistence
- `Watchdog/MenuContent.swift` / `SettingsView.swift` — the dropdown and the window
- `Watchdog/LoginItem.swift` / `Notifier.swift` — `SMAppService` and notifications
- `Watchdog/MenuBarIcon.swift` — the menu bar glyph, composed at runtime
- `Watchdog/Assets.xcassets` — app icon, accent color
- `LaunchAgents/org.lavrard.Watchdog.plist` — launchd job (outside the synchronized folder on purpose:
  inside it, it would be copied to `Contents/Resources`, which is the wrong place for it)

## What the app does

Menu bar utility (`LSUIElement`, no Dock icon) that keeps a list of apps running: it launches them
at login and restarts them whenever they stop, whether from a crash or an accidental Cmd-Q.

- `WatchedApp` — one watched app. Identity is the **bundle identifier**; PIDs are recycled and say
  nothing about a relaunch, and apps move on disk. The path is only a fallback.
- `WatchStore` — the persisted list (UserDefaults, JSON).
- `AppWatcher` — the engine. Push-based, so there is no PID polling: KVO on
  `NSWorkspace.shared.runningApplications` re-runs the sweep the moment any app starts or stops,
  and `NSWorkspace.didTerminateApplicationNotification` is a faster path for the apps it covers. A
  30s timer sweep is the backstop, and is also what launches everything at startup.
- `MenuContent` / `SettingsView` — dropdown and the watch-list window.

### Rules that are easy to break by accident

- **`SMAppService.register()` enables the job outright** — verified with
  `launchctl print-disabled gui/$UID`, which reports `"org.lavrard.Watchdog" => enabled` straight after
  registering. The "added items that can run in the background" notification is macOS *informing*
  the user, not asking them; System Settings → Login Items is where they'd go to turn it off. The
  one case that isn't a boolean is registering again after the user has switched it off there:
  that returns `requiresApproval`, and only System Settings can undo it. Hence `LoginItem.State`'s
  three cases and the button through to Login Items. That state is set outside the app, so the
  pane re-reads it on `didBecomeActiveNotification` instead of trusting what it stored.
- **One control per setting.** There were two "Launch at login" toggles — menu and Settings — each
  holding its own `@State` copy read once at init, so toggling one left the other showing stale
  state. The menu's is gone; Settings owns it.
- **Watchdog keeps *itself* alive with launchd, not with a login item.** A login item only launches
  it once at login; if Watchdog crashed, everything it watches would quietly stop being watched with
  nothing to say so. `LaunchAgents/org.lavrard.Watchdog.plist` is copied into
  `Contents/Library/LaunchAgents` by a Copy Files build phase and registered via
  `SMAppService.agent(plistName:)`. Two keys carry the design: `BundleProgram` (a path *relative to
  the bundle*, so it survives the app being moved — `Program` would hard-code wherever it was when
  registered) and `KeepAlive`/`SuccessfulExit: false` (restart on a crash, respect a deliberate
  Quit). Plain `KeepAlive: true` would relaunch within ~10s and make the Quit menu item a lie.
  launchd throttles respawns to one per 10s, so a crash takes about that long to come back — a
  test that checks after 5s sees `state = spawn scheduled` and wrongly concludes it failed.

- **`NSWorkspace`'s launch/terminate notifications are never posted for `LSUIElement` apps.** That
  is most of what anyone watches — sync clients and password-manager agents are typically accessory
  apps — so notifications alone leave exactly the wrong apps to be caught by the 30s sweep. KVO on
  `runningApplications` does cover them; it's what makes detection immediate. Measured with a pair
  of throwaway stub apps, one accessory and one regular: the regular app fired both channels, the
  accessory app fired only KVO.

- **Never relaunch during logout/shutdown.** macOS quits every app then; relaunching fights the
  system and can stall the shutdown. `AppWatcher.endSession()` latches on
  `NSWorkspace.willPowerOffNotification` and stops all restarts.
- **Every restart waits 30s, and there are only 3 of them.** Crash or Cmd-Q, the handling is the
  same: wait 30s, launch, and if the app dies again within 30s of starting that's the next try in
  the streak. After 3 tries Watchdog gives up and notifies. Surviving longer than 30s resets the
  streak, so an app that's quit once a day always gets the same treatment. There is no backoff and
  no per-app delay — one constant for everything.
- **Uptime comes from `NSRunningApplication.launchDate`, never from when we noticed the app.**
  Stamping "started now" when a sweep first sees an already-running app makes a quit in the first
  30 seconds after Watchdog launches look like a crash, which it isn't — Watchdog has no idea how
  long that app had been up.
- **No escape hatch by design.** A watched app always comes back; to stop that, pause or remove it.
- **Only a real restart notifies.** Launching an app at startup, or because it was just added, is
  not a restart and must stay silent — otherwise logging in fires one notification per watched app.
  A manual retry is silent too: you just asked for it. `launch(_:notifying:)` carries this.
- **The menu's app rows are status, not commands.** They used to relaunch on click, which meant
  clicking a running app "restarted" it and notified. Only a gave-up app is clickable.
- **The app must not be sandboxed** (`ENABLE_APP_SANDBOX = NO`) — a sandboxed app can't launch
  arbitrary third-party apps.

### Bringing a window forward

`.accessory` apps (`LSUIElement`) never come forward on their own, and `NSApp.activate()` on
macOS 14+ is *cooperative* — it does nothing unless the frontmost app yields, which it won't. Use
`NSApp.activate(ignoringOtherApps: true)`, and do it a runloop turn later (`DispatchQueue.main.async`)
because the menu bar menu hands focus back as it dismisses. `SettingsView.bringToFront()` is the one
place that gets this right; copy it rather than reinventing it.

### Debugging

The app logs to the unified log under its own subsystem:

```bash
/usr/bin/log show --last 5m --info --predicate 'subsystem == "org.lavrard.Watchdog"' --style compact
```

Spell out `/usr/bin/log`: `log` is a zsh builtin, so a bare `log show` silently does nothing here —
inside a `#!/bin/bash` script it works either way, which makes the difference easy to miss.
`/usr/bin/log stream --predicate 'subsystem == "org.lavrard.Watchdog"'` follows it live.

End-to-end scripts that seed a watch list (`defaults write org.lavrard.Watchdog …`) or `open` the
built app need the same unrestricted filesystem access as `xcodebuild`. **Those scripts share a
preferences domain with the real app**, so bracket them with
`defaults export org.lavrard.Watchdog <backup>` … `defaults import org.lavrard.Watchdog <backup>` —
seeding a test list overwrites whatever the user is actually watching, and `defaults delete` at the
end throws it away for good.

Never swallow errors with `try?` in the load path — a silently empty watch list looks exactly like a
watcher that isn't running, which is a slow thing to diagnose.

### Sandbox leftovers (this bit us once)

The macOS app template ships sandboxed. Turning `ENABLE_APP_SANDBOX` off is not enough on its own:
`ENABLE_USER_SELECTED_FILES` and `REGISTER_APP_GROUPS` also add container-triggering entitlements,
and once macOS has created
`~/Library/Containers/<bundle id>`, preferences written by the app go *into the container* while
`defaults write <bundle id>` writes to `~/Library/Preferences` — so the app reads an empty watch
list and appears to do nothing. All three settings are now off.

The trap is identity-independent, so it would recur under any bundle identifier. A container left
behind by an earlier build is SIP-protected and can't be deleted from a shell; it's harmless once no
containerizing entitlements remain. Verify with:

```bash
codesign -d --entitlements - --xml /path/to/Watchdog.app | plutil -p -
```

Only `com.apple.security.get-task-allow` (the debug entitlement) should appear.

### Changing `WatchedApp`

`WatchedApp` has a hand-written `init(from:)` that uses `decodeIfPresent` with a default for every
field except the three identity ones (removed fields just fall out — unknown keys are ignored). Keep it that way: a synthesized `Codable` conformance fails to
decode a saved list written before a new property existed, which silently empties the user's watch
list on the next launch. Any new property needs a default there too.

### Launching in the background

Every launch uses `activates = false` (don't steal focus) *and* `hides = true` (don't put windows on
screen) — the latter is the same thing as `open -j` and the Hide checkbox next to a login item.
There's no toggle for it; a restart should never interrupt what you're doing. Verify hidden state
from a shell with `lsappinfo info -only hidden "<App Name>"`, which is a lot less trouble than
asking System Events and tripping an automation prompt.

### The menu bar glyph

A paw badged with a tick / ellipsis / cross / pause, composed at runtime in `MenuBarIcon` and marked
`isTemplate` so macOS tints it for light, dark and highlighted states. It's a template image, so the
badge can only speak through *shape* — no red X, no green tick. Everything is 18pt tall, so the
badge has about 7 points to work with; there's a metrics struct and a sweep harness because the only
way to judge it is to render it at true size and look. A custom illustration was tried here and
failed: outline artwork turns to grey mush below ~24px.

### The countdown

The status line under an app ("Restarting in 22 seconds… (2nd try)") comes from
`AppWatcher.statusText(for:)`, which reads a `tick` property bumped once a second by a task that
only runs while something is counting down. `@Observable` invalidates the views because they read
`tick` through that method — computing the string in the view instead would show a frozen number,
since nothing in the store or the runtime changes between seconds.
