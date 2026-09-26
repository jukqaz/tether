# Changelog

## 2.0.0 (2026-09-26)

First public release.

- Clamshell mode follows power: on while connected, off on battery, and a Mac already closed is put
  to sleep the moment it's unplugged.
- No lock: the screen under the lid is dimmed instead of sleeping the display. Optionally lock
  when the lid closes instead.
- Battery hold with safety limits enforced by the helper (battery temperature by lid state,
  thermal pressure, battery floor, time), adjustable only toward stricter values.
- Heat guard: Low Power Mode for a closed Mac running hot on power.
- Data-based settings: time-weighted battery temperatures, battery use during holds, and
  recommended limits from them.
- Sleep log: duration, charge per hour, sleep and wake causes, dark wakes; alerts on high drain.
- Screen off without locking, idle or on demand.
- `tether` command with `status --json`, `hold`, `sleep`, `blank`, and `run -- <command>`.
- `tether://` URLs, global shortcuts you can re-record.
- Apps keeping the Mac awake, live in Settings and `tether status`.
- Control Center style panel (full and compact), sidebar settings, new icon, English and Korean.
- First-run welcome, update check against GitHub releases, full uninstall.
- Desktop Macs are left alone.
