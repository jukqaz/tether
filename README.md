<p align="center"><img src="docs/images/icon.png" width="128" alt="Tether icon"></p>

<h1 align="center">Tether</h1>

<p align="center">Clamshell mode that follows your power cord, for Apple silicon MacBooks.<br>
<a href="README.ko.md">한국어</a></p>

Close the lid while it's plugged in and your Mac keeps working: no sleep, **no lock**, the screen
under the lid dark. Pull the plug and it sleeps like a laptop should, even when the lid is already
shut and it's in your bag.

<p align="center">
  <img src="docs/images/panel.png" width="300" alt="Tether's menu bar panel">
  <img src="docs/images/settings-history.png" width="500" alt="Tether's settings: history">
</p>

## Why

macOS sleeps a MacBook when the lid closes, unless an external display is attached. Keep-awake
apps and `caffeinate` either don't cover a closed lid, or keep the Mac awake whatever the power
source, so a Mac unplugged with the lid shut can stay awake in a bag. Tether ties clamshell mode to
power instead:

| | Lid open | Lid closed |
|---|---|---|
| **Power connected** | clamshell on | clamshell on: screen dark, session not locked |
| **Power disconnected** | clamshell off | clamshell off, and the Mac sleeps at once |

Because nothing locks, remote desktop sessions, SSH, builds and AI agents keep going with the lid
closed.

## Features

- **Automatic clamshell mode** on power; a closed Mac sleeps the moment you unplug it.
- **No lock**: the built-in screen and keyboard light are dimmed instead of sleeping the display.
  Prefer a lock? Choose "Lock the screen" for when the lid closes.
- **Battery hold**: stay awake on battery for a while, bag included. The helper ends it when the
  battery gets hot, runs low, or time is up. Limits can be made stricter, never looser.
- **Heat guard**: a closed Mac running hot on power is cooled with Low Power Mode, not put to sleep.
- **Data-based settings**: Tether measures this Mac's battery temperatures and battery use and
  recommends limits from them.
- **Sleep log**: how long it slept, charge used per hour, what put it to sleep and what woke it,
  with an alert when sleep drains more than it should.
- **Screen off without locking**: after a few idle minutes, or on demand.
- **`tether run -- <command>`**: keep the Mac awake until a build or agent finishes, then let it
  sleep again.
- **Apps keeping the Mac awake**: see which apps are holding off sleep.
- Global shortcuts, a `tether` command, `tether://` URLs for the Shortcuts app.
- A compact or full menu bar panel, Liquid Glass, English and Korean.

## Requirements

- A MacBook with Apple silicon.
- macOS 26 Tahoe or later.

On a desktop Mac (no lid, no battery) Tether leaves sleep settings alone.

## Install

1. Download `Tether-x.y.z.zip` from [Releases](https://github.com/jukqaz/tether/releases), unzip it
   and move **Tether.app** to Applications.
2. Tether isn't notarized (that needs a paid Apple developer account), so macOS blocks the first
   launch. Open it once, then go to **System Settings › Privacy & Security** and click
   **Open Anyway**. Or, in Terminal:

   ```sh
   xattr -dr com.apple.quarantine /Applications/Tether.app
   ```

3. Click **Install Helper…** in the welcome window and enter your administrator password once.

Prefer to see what you run? [Build it yourself](#build-from-source): it takes a minute.

## Use

- **Menu bar panel**: the state circle turns Tether on and off; start a battery hold, turn the
  screen off, or sleep now. The footer switches between the full and compact panels.
- **Settings** (the gear): lid behaviour, safety limits with recommendations, history,
  notifications, shortcuts, and everything Tether changes on your Mac.
- **Shortcuts**: ⌃⌥⌘S sleep now, ⌃⌥⌘T on/off, ⌃⌥⌘B screen off. Change them in Settings.
- **Terminal**: turn on "Install the tether command" in Settings › Automation.

```sh
tether status [--json]          # state, for people or scripts
tether on | off | toggle
tether sleep                    # sleep now, even on power
tether hold 1h30m               # stay awake on battery too (up to 4 h); tether hold off
tether run -- make release      # stay awake until the command finishes
tether blank                    # screen off without locking
```

The same actions work as URLs, for the Shortcuts app's "Open URL": `tether://sleep`,
`tether://blank`, `tether://toggle`, `tether://hold/90m`.

## How it works

A small helper runs as a root LaunchDaemon. It follows the power source, the lid and sleep and
wake, sets `pmset disablesleep` on power, clears it on battery, and puts a closed Mac to sleep
itself, because macOS only reconsiders sleep when the lid moves. The menu bar app keeps the
display from sleeping (so nothing locks) and dims the screen under the lid instead. The helper
applies all safety limits, so they hold even with the app closed.

Details and reasoning: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## What Tether changes on your Mac

| Setting | When | Visible in System Settings |
|---|---|---|
| Prevent sleep (`pmset disablesleep`) | on while power is connected | no (a hidden setting) |
| Low Power Mode | only during the heat guard or a battery hold, then restored | yes, while on |
| Screen brightness, keyboard light | dimmed while the lid is closed, restored when it opens | yes, while dimmed |
| Background items | the helper and "open at login" | General › Login Items |

It never changes sleep or display timers, the lock password, the screen saver or input sources.
Settings › System shows the live values.

## Privacy

No analytics, no account. Once a day Tether asks GitHub for the latest release version (you can
turn this off). Measurements and logs stay on your Mac.

## Uninstall

Settings › System › **Uninstall Tether…** removes the helper (turning "prevent sleep" back off),
its files, the login item, the `tether` command and preferences, then moves the app to the Trash.

## FAQ

**How is this different from Amphetamine or `caffeinate`?** Those keep a Mac awake. Tether decides
by power source: automatically awake with the lid closed on power, asleep the moment you unplug,
and never locked while awake.

**Does it work with an external display?** Yes. macOS already keeps a closed Mac awake with an
external display on power; Tether adds the unplug rule and leaves the displays to macOS.

**Can it limit charging like AlDente?** No. macOS 26.4 added a charge limit of its own (Battery ›
Charging), and macOS 27 blocks third-party apps from controlling charging.

**Why "not notarized"?** Notarization needs a paid Apple developer account. The source is here,
and building it yourself is one script.

## Build from source

Requires Xcode 26 (Swift 6) on macOS 26 or later.

```sh
git clone https://github.com/jukqaz/tether.git && cd tether
swift test
scripts/build.sh                     # ad-hoc signed build/Tether.app
cp -R build/Tether.app /Applications/
```

`scripts/release.sh` also packs `dist/Tether-<version>.zip` with its SHA-256.

## License

[MIT](LICENSE)
