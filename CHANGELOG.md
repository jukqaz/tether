# Changelog

## 2.0.0 (2026-09-26)

First public release.

- Clamshell mode follows power: on while connected, off on battery, and a Mac already closed is put
  to sleep the moment it's unplugged. Its switch turns it off until power is connected again.
- No lock: the screen under the lid is dimmed instead of sleeping the display. Optionally lock
  when the lid closes instead.
- Battery hold with safety limits enforced by the helper (battery temperature by lid state,
  thermal pressure, battery floor, time), adjustable only toward stricter values.
- Heat guard: Low Power Mode for a closed Mac running hot on power, and sleep if it keeps
  overheating with no display attached (a bag on a power bank counts as power).
- Low Power Mode only where you allow it (during battery holds; when hot on power, from "serious",
  from "fair" or never), and your own change to it is never undone.
- A watchdog LaunchDaemon that turns sleep back on if the helper ever stops while sleep is off on
  battery.
- A Mac put to sleep on power stays asleep through Power Nap's dark wakes; a charger that can't
  keep up can no longer run the battery flat with the lid closed; a battery hold can't start at or
  below the floor; the app relaunches after a crash.
- Data-based settings: time-weighted battery temperatures, battery use during holds, and
  recommended limits from them; "Adjust to this Mac" applies them by itself as measurements come
  in, never looser than the defaults.
- Sleep log: duration, charge per hour, sleep and wake causes, dark wakes; alerts on high drain.
- Screen off without locking after a few idle minutes.
- `tether` command with `status --json`, `hold`, `sleep`, `run -- <command>` and `diagnose`.
- `tether://` URLs for the Shortcuts app.
- Apps keeping the Mac awake, live in Settings and `tether status`.
- Troubleshooting: detailed logging and a Markdown report with masked names, from Settings or
  `tether diagnose --record`.
- Control Center style panel (full and compact) with a clamshell switch and a countdown to the
  second; a status item with a ring that empties during a battery hold.
- Icon Composer app icon (Liquid Glass, dark, clear and tinted), sidebar settings, English and
  Korean with a choice in Settings.
- `tether doctor` and a checks list in Settings › System and at the top of the report; "+30m"
  for a running battery hold (`tether hold +30m`), still capped at 4 hours from its start.
- In-place help: an ⓘ next to each setting that needs explaining (what it does, the words it
  uses), Help › Tether Help opening the README, and a glossary in the README.
- First-run welcome, update check against GitHub releases, full uninstall.
- A quiet panel: controls that can't act right now are hidden rather than greyed out, and there
  are no lid-open or toggle notifications (the last lid session is in the panel and History).
- Desktop Macs are left alone.
