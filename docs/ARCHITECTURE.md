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

On battery the hold turns Low Power Mode on (`pmset -b lowpowermode 1`, previous value restored).
Ending a hold with the lid closed sleeps the Mac through the same path as an unplug. A hold is
consumed when it ends, on "sleep now", and on any helper restart or reboot, so it never comes back
on its own. Battery temperature is `BatteryData.Temperature` (0.01 °C) on the `AppleSmartBatteryPack`
registry entry (macOS 27; older layouts kept it on `AppleSmartBattery`, tried as a fallback);
thermal pressure is `ProcessInfo.thermalState`, also watched via `com.apple.system.thermalpressurelevel`.
The app notifies the reason after wake, and alerts if the helper stops answering for 2 minutes.

## Heat guard (lid closed on AC)

Clamshell on AC still blocks the hinge vent, but sleeping would kill the remote session or job
that clamshell is for. So the helper only cools: thermal pressure *serious* with the lid closed
on AC turns AC Low Power Mode on (`pmset -c lowpowermode 1`, previous value restored), released
after 2 minutes at *fair* or below, or at once when the lid opens or power is pulled. *Critical*
for 3 minutes raises a notification (visible over remote desktop). No auto-sleep. Settings → Safety
can turn the guard off or start it at *fair* (`control.json` → `heatGuard`).

## Screen off without locking

The no-lock assertion would also keep an idle screen lit forever. With a screen in view in
clamshell mode (lid open, or an external display), after N minutes without input (Settings → Lid & Screen, default 10 min, off/5/10/20/30)
the app blanks every display (gamma to black, built-in panel and keyboard dimmed) instead of
sleeping them; any input restores it, still unlocked. Skipped while another app holds a display
assertion (video, presentation, call). "Screen Off" (panel, ⌃⌥⌘B, `tether blank`) does the same on
demand, ignoring input for 1.5 s so the click or hotkey itself does not undo it. Gamma changes die
with the app process, so a crash never leaves a black screen.

Settings → Lid & Screen → When the lid closes → Lock the screen is the opposite choice for people who want the Mac
locked when they walk away: Tether then drops its no-lock assertion (macOS display sleep and lock
settings apply as usual), locks at once when the lid closes (`SACLockScreenImmediate`, the ⌃⌘Q
path), and skips blanking. Closing the lid while an external display is in use never locks.

## Sessions, stats, menu bar

- When the lid opens after ≥ 5 minutes closed in clamshell mode, the app shows (and notifies)
  a summary: duration, peak battery temperature and thermal level, battery change, Low Power Mode.
- The panel shows time awake with the lid closed today / 7 days, a bar per day, and counts of
  forced sleeps, battery holds and heat-guard activations (`usage.json`, kept 7 days).
- The menu bar shows the hold countdown (`bag 1:23`) on battery, or the battery temperature
  (`39°`) while the heat guard is on.

## Hotkeys, URLs, terminal

| | Hotkey | URL | Terminal |
|---|---|---|---|
| Status | | | `tether status [--json]` |
| On / off / toggle | ⌃⌥⌘T (toggle) | `tether://on` `off` `toggle` | `tether on` `off` `toggle` |
| Sleep now | ⌃⌥⌘S | `tether://sleep` | `tether sleep` |
| Screen off, no lock | ⌃⌥⌘B | `tether://blank` | `tether blank` |
| Battery hold | | `tether://hold/90m`, `?minutes=90`, `hold/off` | `tether hold 1h30m`, `hold off` |

Hotkeys use Carbon `RegisterEventHotKey` (no Accessibility permission) and can be re-recorded in
Settings → Automation (any combination with ⌘, ⌥ or ⌃; labels come from the US layout). "Sleep now" (button,
hotkey, URL, `tether sleep`) waits up to 3 s for input to settle first: any input during powerd's
~5 s pre-sleep window cancels the sleep, so a finger lifting after the click or the hotkey keys
being released would otherwise wake the Mac straight back up. The `tether` binary
lives at `Tether.app/Contents/Helpers/tether`; Settings → Automation links it into `~/.local/bin` (or `/usr/local/bin`).
It writes the same control file as the app and waits up to 3 s for the helper to apply it. Use
Shortcuts' "Open URL" or "Run Shell Script" for automations.

## Panel

Laid out like macOS Control Center: glass modules, with the state circle doubling as the on/off
control. Full: state, status (power, lid, battery temperature), battery hold (durations in a menu,
then a countdown ring), screen off and sleep now, the last lid session, and today (lid-closed time,
a bar per day, and how the last sleep went). Compact: the state module and one row of round
buttons. Switch with the footer button or Settings → General.

The icon and menu bar mark are a crescent moon holding the power stroke: sleep, governed by power
(`scripts/make-icon.swift`, `TetherGlyph`). Solid when clamshell is on, outlined on battery, struck
through when Tether is off; SF Symbols where they say it better (hold, heat, problems).

## Settings window

A System Settings style sidebar (the gear in the panel, or ⌘, while it is open):

| Page | Contents |
|---|---|
| General | launch at login, panel size, Liquid Glass, menu bar details |
| Lid & Screen | lid close: stay unlocked (dim) or lock, idle screen-off delay, screen off now |
| Safety | this Mac's measurements with recommended limits, stricter battery-hold limits, heat guard |
| History | daily peak battery temperature against the limits, recent sleeps (drain and causes), lid sessions, 7-day totals |
| Notifications | notifications per kind |
| Automation | record hotkeys, install the `tether` command, command and URL reference |
| System | helper status/reinstall/remove/log, live values of what Tether changes, links to System Settings |

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

## 2.0 additions

- **Languages.** Strings sit side by side in code, `L("English", "한국어")`, chosen from the
  first preferred language. The app bundle, the helper and the `tether` command share this with no
  resource bundles (SwiftPM resource bundles don't fit inside an app bundle cleanly).
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
- **Updates.** Once a day the app asks the GitHub API for the latest release tag; nothing else is
  sent. Off in Settings → System.
- **Uninstall.** The helper script also removes a `/usr/local/bin/tether` link into Tether.app; the
  app removes its login item, `~/.local/bin/tether`, its preferences, then moves itself to the Trash.

## Layout

- `TetherCore` — pure policies (`Policy`, `SafetyPolicy`, `ACThermalPolicy`, `ScreenPolicy`),
  session/stats trackers, command parsing, Korean texts, probes (IOPS + IOPMrootDomain registry),
  shared files.
- `TetherHelper` — root LaunchDaemon `local.tether.helper`. Reacts to power-source, lid, sleep/wake
  and settings notifications (coalesced 0.1 s) plus a 30 s fallback timer. Owns `SleepDisabled`
  via `pmset -a disablesleep`, so the rule holds before login and without the app running.
- `Tether` — SwiftUI `MenuBarExtra` panel (status, on/off, battery hold, screen off, sleep now)
  and `Settings` window; launch at login (on by default, per-user LaunchAgent `local.tether.app`),
  helper install/update, notifications, hotkeys, `tether://` URLs, and `ScreenGuard` (no-lock,
  dimming, blanking). Keep it running:
  without it the display sleeps after its timer and the Mac locks.
- `TetherCLI` — the `tether` command.

Files: `/Library/Application Support/Tether/{control,status,usage}.json` (control is
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
swift test                                         # policy scenarios
.build/debug/Tether --render-preview /tmp/p.png [dark] [--sample]   # draw the panel (live data)
.build/debug/Tether --render-menubar /tmp/m.png "1:23" bag.fill        # draw a status item
.build/debug/Tether --render-settings /tmp/s.png system [dark]         # draw a settings tab
swift scripts/make-icon.swift && iconutil -c icns Resources/Tether.iconset -o Resources/Tether.icns
.build/debug/TetherHelper --dry-run --control /tmp/c.json --status /tmp/s.json
```

The dry-run helper logs decisions without calling `pmset` or `IOPMSleepSystem`. Add
`--fake fake.json` (keys: `power`, `lid`, `sleepDisabled`, `temperature`, `thermal`, `battery`,
re-read on every check) to walk a battery-hold or heat-guard scenario without unplugging; post
`notifyutil -p local.tether.control` to trigger a check. SwiftPM needs to run outside the
Claude Code sandbox (`swift build` writes build service data it cannot write).
