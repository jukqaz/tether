# Tether

A menu-bar app for keeping Apple Silicon Macs working, with optional closed-lid support on MacBooks. [한국어 안내](README.ko.md)

Requires an Apple Silicon Mac running macOS 26 or later. See [release notes](CHANGELOG.md) for changes and the [feature specification](docs/PRODUCT-SPEC.ko.md) for options and defaults.

## Features

- AC automatic work by default, with an explicitly selected power range and AND/OR condition groups. New installations default to automatic OFF and lid support OFF independently. Immediate new battery automatic work after unplugging requires its separate explicit option.
- Timed or indefinite manual work on AC. Battery limits default to two hours, with explicit 30/60/120/240-minute or unlimited choices. Timers continue on AC; the original battery-use anchor never resets, and the battery ceiling is enforced on battery.
- Unplugging ends all work by default. End-automatic and continue-eligible options preserve only eligible requests with their original identities, deadlines and battery limits. Ended work never replays.
- Optional MacBook lid support. After confirmed own restoration, managed closed-lid unplug and battery expiry may issue one Sleep request. Ordinary AC-condition endings and cancellation follow macOS. Request acceptance is not actual Sleep proof.
- OS thermal and battery protection, current-owner verification, and recovery of Tether's own state. Foreign assertions/global settings are not forcibly removed; general work remains separate from lid support.
- Advanced automatic triggers can observe selected apps, processes and structured AC task events. Process-bound manual work and `tether run` are no longer provided.
- Optional timer-end notifications and once-per-request expiry warnings (OFF by default). Updates are explicitly installed, with the existing restoration and safe-replacement checks.
- Global hotkeys, rule rehearsal, settings history/rollback and after-work update reservations have been removed to keep the app focused on sleep prevention.
- One menu and four Settings pages: Power & Lid, Manual Keep-awake, Protection & Diagnostics, and General. Advanced editors, optional display-idle prevention and bounded local diagnostics remain available from their owning pages. Desktop Macs skip helper installation and hide lid/battery options.

Display-idle prevention does not promise unlocked display-off operation, defeat manual locking or change macOS password policy. No automatic unlock, fake input, fan/charging control or guaranteed wake from cable attachment. CPU/transfer conditions are experimental; unverified media/partial-download inference and widgets/Controls remain staged.

[Product contract](docs/PRODUCT-SPEC.ko.md) · [Architecture](docs/ARCHITECTURE-REDESIGN.ko.md) · [Design](DESIGN.md)

## Validation and installation

General keep-awake works without the administrator helper. To use a MacBook with the lid closed, open the lid and prepare the helper in **Settings → Power & Lid**. Automatic start and closed-lid permission are separate choices.

Tether checks one signed feed for stable updates. Beta releases are retained as release history; the next stable candidate is **2026.11.1, build 60**.

[Published releases](https://github.com/jukqaz/tether/releases) · [Installation](docs/INSTALL-AND-TEST.ko.md) · [Validation checklist](docs/VALIDATION-CHECKLIST.ko.md) · [Release procedure](docs/RELEASING.ko.md)

## Build and test

Use a macOS 26+ SDK and Icon Composer support, Swift 6 and Python 3. Select the compatible Xcode through `xcode-select`. The deployment target is macOS 26; `scripts/build.sh` checks arm64 and the minimum OS of bundled code, including Sparkle.

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/p0-module-cache" \
  python3 scripts/test-p0-automated.py --out .build/verification/p0-<new-run>
```

The native assertion checks own only their test requests and do not put the Mac to sleep. Helper tests use isolated sensor/power fixtures. `sh scripts/build-preview.sh` builds an unprivileged dry-run UI preview, with separate preferences and no production power writes.

[DESIGN.md](DESIGN.md) defines the current palette, standard macOS bordered controls, opaque reading surfaces, spacing and input behavior for Settings and the menu panel. Custom Liquid Glass effects are not used. Follow it when changing UI, and use [automated testing](docs/AUTOMATED-TESTING.ko.md) and [the design review](docs/DESIGN-REVIEW.ko.md) to distinguish source tests, shared-Scene UI tests, installation inspection and physical acceptance. Dated mockups and earlier validation totals are reference history, not the current design or acceptance result.

CLI session commands use a running app of the same version. Examples include `condition ac`, `manual unlimited`, `manual 30m`, `manual +15m`/`+30m`, `manual off`, structured `task` events, `hold`, `sleep`, `doctor`, `diagnose` and `displays`. Removed `run` and `manual --pid` commands are rejected before execution. Extensions and power changes never bypass the request's captured scope or battery ceiling. Use `tether --help` for exact syntax.

General → Advanced Integrations → Command-line Control provides copyable commands and URLs from the running app's bundled CLI. Notifications are edited inline in General; importing settings still requires review and saves inactive preset copies. Quitting ends Tether keep-awake and restores its power and display changes while retaining saved preferences.

Previous records remain in [the changelog](docs/CHANGELOG.ko.md); they are not acceptance evidence for this candidate.
