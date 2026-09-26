# How Tether works

Clamshell mode (lid closed, Mac awake) only while on AC power. This is the design and the
reasoning behind it; the [README](../README.md) is the user-facing overview.

| Event | Lid open | Lid closed |
|---|---|---|
| Power connected | clamshell on | clamshell on: screen dark, session **not locked** |
| Power disconnected | clamshell off | clamshell off, then sleep immediately |

macOS only evaluates the lid when it opens or closes, so clearing `SleepDisabled` with the lid
already shut leaves the Mac awake. The helper requests sleep itself (`IOPMSleepSystem`, retried
while powerd propagates the cleared flag; powerd then lingers ~5 s before sleeping). Dark wakes
(Power Nap) are left alone, and a lid closing on battery is left to macOS's own clamshell sleep.

Display sleep locks this Mac immediately, so clamshell mode never sleeps the display. The app
holds `PreventUserIdleDisplaySleep` while clamshell is on and, with the lid shut and no external
display, dims the built-in panel and keyboard backlight to 0 (private DisplayServices /
CoreBrightness), restoring them only once the lid is open again. Restoring at unplug with the
lid still shut raced macOS's battery dimming (`lessbright`) and left the panel at half brightness.

Clamshell mode has one switch, at the top of the panel (`control.json` → `enabled`). It is on by
default, so connecting power turns clamshell mode on by itself; off leaves the lid to macOS. While
it is on, macOS's own Sleep menu item does nothing (sleep is disabled system-wide), which is why
`tether sleep` and `tether://sleep` exist for scripts.

## Code layout

```
Sources/
  TetherCore/            shared by all three executables, no UI
    IPC/                 paths, control.json (+ ControlStore), status.json, helper state,
                         JSONFile/JSONWatch, Darwin notifications
    Policy/              the rules: clamshell (Policy), battery hold (SafetyPolicy), heat on AC
                         (ACThermalPolicy), screen (ScreenPolicy), recommendations (Advisor),
                         what to show (TetherState)
    Usage/               temperature histograms, daily stats, lid sessions, the sleep log
    System/              read-only probes (IOPS, IOPMrootDomain, assertions), Shell, input idle time
    Commands/            `tether` words and `tether://` URLs, hold durations
    Text/                English/Korean strings (`L`), wording shared by app and CLI
    Diagnostics/         the troubleshooting report
    Support/             version comparison, app-presence tracking
  TetherHelper/          root LaunchDaemon: Helper.swift decides; Helper+Events, +BatteryHold,
                         +HeatGuard, +Usage, +Readings, +Output, +Retire do one job each
  TetherCLI/             `tether`: main.swift dispatches; one file per command group
  Tether/                the menu bar app
    App/                 @main, scenes, URL handling; PreviewRenderer for screenshots
    Model/               AppModel (state + commands) with +Presentation, +Safety, +Diagnostics;
                         Notifier, UpdateChecker, SystemIntegration, HoldClock, SampleData
    MenuBar/             the mark (TetherGlyph), the status item image, its SwiftUI label
    Panel/               TetherPanel and one file per module; PanelStyle holds metrics and styles
    Settings/            SettingsView (sidebar) and one file per page
    Screen/              ScreenGuard (no-lock, dimming, idle blanking) and display controls
    Onboarding/          the welcome window
Resources/               Info.plist, AppIcon.icon (Icon Composer), LaunchDaemon plists, scripts
```

Policies are pure functions of their inputs, which is what the tests exercise. `AppModel` only
holds state and forwards commands; how the state reads is `AppModel+Presentation`, built on
`TetherState.resolve`, which is tested in Core. Side effects outside the app bundle (login item,
`tether` link, root scripts) go through `SystemIntegration`, which throws user-facing messages.

## Battery hold

The battery hold arms a one-shot hold (30 min – 4 h, capped at 4 h from when the helper
first sees it) that keeps clamshell mode on battery, e.g. to finish a job in a bag. The helper
enforces every limit itself, so they hold with the app closed:

| Limit | Lid closed (maybe a bag) | Lid open (in use) |
|---|---|---|
| End immediately | battery ≥ 43 °C or thermal critical | battery ≥ 45 °C or thermal critical |
| End after 60 s | battery ≥ 40 °C or thermal serious | — |
| Always | battery ≤ 20 %, time up, battery temperature unreadable (fail safe) | same |

These are the loosest values allowed. Settings → Safety can only tighten them (battery floor up to
50 %, lid-closed limit down to 38 °C with the one-minute limit 3 °C below it, lid-open limit down to
40 °C, at most 1–4 h). The choice travels in `control.json` as `limits`, and the helper clamps
it again, so a hand-edited file cannot loosen anything; it logs the limits in force whenever
they change.

On battery the hold turns Low Power Mode on (`pmset -b lowpowermode 1`, previous value restored)
and the helper checks every 10 seconds. Ending a hold with the lid closed sleeps the Mac through
the same path as an unplug. A hold is consumed when it ends, on "sleep now", and on any helper
restart or reboot, so it never comes back on its own. Battery temperature is
`BatteryData.Temperature` (0.01 °C) on the `AppleSmartBatteryPack` registry entry (macOS 27; older
layouts kept it on `AppleSmartBattery`, tried as a fallback); thermal pressure is
`ProcessInfo.thermalState`, also watched via `com.apple.system.thermalpressurelevel`. The app
notifies the reason after wake, and alerts if the helper stops answering for 2 minutes.

## Heat on AC with the lid closed

Clamshell on AC still blocks the hinge vent, and sleeping would end the remote session or job that
clamshell is for, so the helper cools first: thermal pressure *serious* with the lid closed on AC
turns AC Low Power Mode on (`pmset -c lowpowermode 1`, previous value restored), released after 2
minutes at *fair* or below, or at once when the lid opens or power is pulled. *Critical* for 3
minutes raises a notification (visible over remote desktop). Settings → Safety can turn the guard
off or start it at *fair* (`control.json` → `heatGuard`).

A power bank counts as AC, so "on power with the lid closed" may also be a bag. With no external
display attached, *critical* for 2 minutes or a battery at 45 °C for a minute (above every hold
limit) puts the Mac to sleep through the "sleep now" path (`ACThermalPolicy.shouldSleep`, event
`overheatSleep`, `status.json` → `overheatSleepAt`, reported by the app after wake). With an
external display it's a desk, and only the guard and the alert apply. While this is building up
the helper checks every 10 seconds.

## Safety net for the helper itself

`SleepDisabled` is a system setting that outlives the process that set it. If the helper stopped
while it was on and the Mac then ran on battery with the lid closed, nothing would put it to sleep:

- The helper clears it on SIGTERM (normal stop, uninstall) and re-evaluates on every start; launchd
  restarts it after a crash (`KeepAlive`).
- `local.tether.watchdog` is a second LaunchDaemon that launchd runs every 60 seconds: a plain
  shell script (`tether-watchdog.sh`), so it works even when the helper binary can't. On battery,
  with `SleepDisabled` on and `status.json` older than 3 minutes (the helper rewrites it at least
  every 30 seconds), it runs `pmset -a disablesleep 0` and logs to the helper log.
- An app dragged to the Trash is noticed by the helper (`AppPresence`, 10-minute grace): it restores
  normal sleep and Low Power Mode, removes itself, the watchdog, the `tether` links and login items
  that pointed into the app, then boots itself out.

## Screen off without locking

The no-lock assertion would also keep an idle screen lit forever. With a screen in view in
clamshell mode (lid open, or an external display), after N minutes without input (Settings → Lid &
Screen, default 10 min, off/5/10/20/30) the app blanks every display (gamma to black, built-in panel
and keyboard dimmed) instead of sleeping them; any input restores it, still unlocked. Skipped while
another app holds a display assertion (video, presentation, call). Gamma changes die with the app
process, so a crash never leaves a black screen. To turn the screen off right away, close the lid.

Settings → Lid & Screen → When the lid closes → Lock the screen is the opposite choice for people
who want the Mac locked when they walk away: Tether then drops its no-lock assertion (macOS display
sleep and lock settings apply as usual), locks at once when the lid closes (`SACLockScreenImmediate`,
the ⌃⌘Q path), and skips blanking. Closing the lid while an external display is in use never locks.

## Menu bar and panel

The status item is drawn with AppKit into one template image (`MenuBarIcon`): the mark, and during
a battery hold a ring that empties as the hold runs out plus the time left (`29:41`, `1:29:41` from
an hour up), redrawn every second by `HoldClock`, which only runs while a hold does. While a closed
Mac runs hot on power the battery temperature (`41°`) appears instead. Settings → General turns
these details off.

The mark is a closed laptop lid with a crescent: solid with its cable while clamshell is on,
solid without the cable during a battery hold, outlined on battery, struck through when switched
off; SF Symbols only for problems. The cable leaves the lid's side, not its bottom: at 16 pt a cable
from the bottom reads as a speech bubble.

The panel is laid out like Control Center: glass modules on one spacing grid (`PanelStyle.Metrics`).
Full: the state with the clamshell switch, status (power, lid, battery temperature), the battery
hold (durations in a menu, then the countdown to the second with a bar), the last lid session, and
today (lid-closed time, a bar per day, how the last sleep went). Compact: the state module, and a
row with the hold, the temperature and the footer buttons.

## App icon

`Resources/AppIcon.icon` is an Icon Composer document: a blue fill, the lid (SVG, with the crescent
cut out) and the cable (a filled outline: the glass renderer closes open paths and lights the
seam). `scripts/build.sh` compiles it with `actool` into `Assets.car` (Liquid Glass, and the dark,
clear and tinted looks macOS 26 generates) plus a flat `AppIcon.icns`; Info.plist names both
`AppIcon`.

## URLs and terminal

| | URL | Terminal |
|---|---|---|
| Status | | `tether status [--json]` |
| On / off / toggle | `tether://on` `off` `toggle` | `tether on` `off` `toggle` |
| Sleep now | `tether://sleep` | `tether sleep` |
| Battery hold | `tether://hold/90m`, `?minutes=90`, `hold/off` | `tether hold 1h30m`, `hold off` |
| Stay awake for a command | | `tether run [--max 2h] -- <cmd>` |
| Troubleshooting report | | `tether diagnose [--record] [--out f] [--hours n]` |

"Sleep now" waits up to 3 s for input to settle first: any input during powerd's ~5 s pre-sleep
window cancels the sleep, so the key press that ran it would otherwise wake the Mac straight back
up. The `tether` binary lives at `Tether.app/Contents/Helpers/tether`; Settings → Automation links it
into `~/.local/bin` (or `/usr/local/bin`). It writes the same control file as the app and waits up
to 3 s for the helper to apply it. Its language follows the app's (Settings → General), read from
the app's preferences.

## Settings window

A System Settings style sidebar (the gear in the panel, or ⌘, while it is open):

| Page | Contents |
|---|---|
| General | launch at login, language, panel size, Liquid Glass, menu bar details |
| Lid & Screen | lid close: stay unlocked (dim) or lock, idle screen-off delay |
| Safety | this Mac's measurements with recommended limits, stricter battery-hold limits, heat guard |
| History | daily peak battery temperature against the limits, recent sleeps (drain and causes), lid sessions, 7-day totals |
| Notifications | notifications per kind |
| Automation | install the `tether` command, command and URL reference |
| System | helper status/reinstall/remove/log, live values of what Tether changes, apps keeping the Mac awake, diagnostics, updates, uninstall |

## Data-based settings

The helper measures, every check, time-weighted battery temperature for lid closed (awake) and lid
open, charge used during battery holds, and the highest thermal pressure with the lid closed
(`usage.json`, 7 days). `Advisor` turns that into recommendations that only pick among the
stricter-than-default choices: a temperature limit 4 °C above the usual (95th percentile) peak, so
ordinary use never trips it and a bag soon does; the longest hold the measured drain allows from
the usual starting charge; the heat guard from "fair" when the lid-closed Mac often runs hot.
Nothing is recommended before 30 minutes of lid-closed data.

## Sleep log

On "will sleep" the helper notes the time, charge and power source; on the next full wake it
closes the record with IOPMrootDomain's "Last Sleep Reason", "Wake Type"/"Wake Reason" and whether
Tether asked for the sleep (`SleepRequestedByPID`). Dark wakes in between are counted, cancelled
sleeps (under a minute) dropped, and charge per hour computed for sleeps on battery of 30 minutes or
more. Above 3 %/h (1–2 % is typical) the app notifies with the wake cause. This is the check that a
Mac Tether put to sleep with the lid shut really stayed asleep in the bag.

## Diagnostics

`Diagnostics.report` builds one Markdown document for a person or an AI assistant: how Tether is
meant to behave (so the logs can be checked against it), the state now, the limits in force,
`control.json`, other apps' power assertions, recent sleeps, lid sessions, 7 days of stats, the
helper log, the relevant `pmset -g log` lines (sleep, wake and Tether's own assertions; periodic
"Summary" repeats dropped) and the app's unified log (subsystem `io.github.jukqaz.tether`).
The home folder, user name, full name and host name are masked. "Detailed logging"
(`control.json` → `debugLog`) makes the helper log every check with its inputs and decision, and
every sleep/wake message. The app saves the report to the Desktop or copies it; `tether diagnose
--record` turns detailed logging on while you reproduce a problem, then reports from that moment.

## Performance

A menu bar utility should cost nothing while nothing happens:

- The helper is event-driven (power source, lid, sleep/wake, thermal pressure, settings; bursts
  coalesced for 0.1 s) with a 30 s safety timer, 10 s only during a battery hold or overheating.
  It writes `status.json` every pass (the heartbeat the app and the watchdog check) but
  `usage.json` only when a sleep or lid session is recorded, or every 5 minutes.
- IOPMrootDomain is looked up once per process, not per property read.
- The app refreshes on the helper's status notification, on display changes, and on a 5 s timer
  (with 1 s tolerance) for idle blanking. `JSONWatch` decodes a file again only when its inode,
  size or modification time changed, and `AppModel` publishes only values that changed, so SwiftUI
  redraws nothing on an idle tick.
- The one-second tick lives in `HoldClock`, which only the countdown views and the status item
  observe, and only runs during a battery hold. The status item image is drawn directly with
  AppKit; still images are cached.

## 2.0 notes

- **Languages.** Strings sit side by side in code, `L("English", "한국어")`. The choice in Settings →
  General (or macOS's language) applies to the app and to the `tether` command, which reads it from
  the app's preferences. No resource bundles (SwiftPM resource bundles don't fit inside an app
  bundle cleanly).
- **Desktops.** Without a built-in battery and a lid, every moment looks like "on AC", which would
  mean never sleeping. The helper checks `SystemProbe.isSupportedMac` at start and, on a desktop,
  only reports; the app explains and does nothing.
- **`tether run -- <cmd>`.** Arms a battery hold sized to the command (capped by the user's
  maximum), runs the command with the terminal attached, ends the hold it armed when the command
  exits (a hold armed by someone else is left alone), and exits with the command's status. SIGINT
  reaches the command through the terminal; tether ignores it after launching so it can clean up.
- **Apps keeping the Mac awake.** `IOPMCopyAssertionsByProcess`, keeping system and display
  assertions of other processes; powerd's own display-on assertion is dropped. Process names come
  from the assertion's "Process Name" (proc_name cannot read root processes).
- **Bundle identifier.** `io.github.jukqaz.tether` since 2.0; settings from `local.tether` are
  copied over once. The helper and watchdog labels stay `local.tether.*`.
- **Translocation.** An app opened straight from Downloads runs from a random temporary path; the
  app refuses to install the helper from there and asks to be moved to Applications first.
- **Updates.** Once a day the app asks the GitHub API for the latest release tag; nothing else is
  sent. Off in Settings → System.

Files: `/Library/Application Support/Tether/{control,status,usage,helper-state}.json` (control is
admin-writable), log at `/Library/Logs/Tether/helper.log`.

## Build and install

```sh
scripts/build.sh                                   # ad-hoc signed build/Tether.app
ditto build/Tether.app /Applications/Tether.app
open /Applications/Tether.app                      # then Install Helper… (admin password once)
```

Uninstall: Settings → System → Uninstall Tether… (restores `disablesleep 0`, removes everything).

## Test

```sh
swift test                                                   # policies and records
.build/debug/Tether --render-preview /tmp/p.png [dark] [--sample] [--hold] -liquidGlass NO
.build/debug/Tether --render-settings /tmp/s.png system [dark] -liquidGlass NO
.build/debug/Tether --render-menubar /tmp/m.png              # every status item state
.build/debug/TetherHelper --dry-run --control /tmp/c.json --status /tmp/s.json
```

Liquid Glass does not draw in an offscreen window, hence `-liquidGlass NO` for screenshots. The
dry-run helper logs decisions without calling `pmset` or `IOPMSleepSystem`. Add `--fake fake.json`
(keys: `power`, `lid`, `sleepDisabled`, `temperature`, `thermal`, `battery`, re-read on every check)
to walk a battery-hold or overheating scenario without unplugging; post
`notifyutil -p local.tether.control` to trigger a check. SwiftPM needs to run outside the
Claude Code sandbox (`swift build` writes build service data it cannot write).
