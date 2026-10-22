# Tether

A menu-bar app for keeping Apple Silicon Macs working, with optional closed-lid support on MacBooks. [한국어 안내](README.ko.md)

**Product direction: simple and reliable.** [The feature specification](docs/PRODUCT-SPEC.ko.md) is the single source for scope and defaults. [The document index](docs/README.md) separates current requirements, UI/copy, acceptance plans and historical evidence. The existing source candidate described below does not yet implement every newly specified brightness or compact statistics/diagnostics view.

**Local candidate58 · macOS26+ · P0 power, termination and recovery update.** This ad-hoc signed development candidate has not replaced the installed app or been published. [Current implementation and evidence](../../outputs/tether-p0-implementation-20261021/RESULT.ko.md). The complete V5 extension catalog is not yet implemented.

## Features

- AC automatic work by default, with an explicitly selected power range and AND/OR condition groups. New installations default to automatic OFF and lid support OFF independently. Immediate new battery automatic work after unplugging requires its separate explicit option.
- Timed or indefinite manual work on AC. Battery limits default to two hours, with explicit 30/60/120/240-minute or unlimited choices. Timers continue on AC; the original battery-use anchor never resets, and the battery ceiling is enforced on battery.
- Unplugging ends all work by default. End-automatic and continue-eligible options preserve only eligible requests with their original identities, deadlines and battery limits. Ended work never replays.
- Optional MacBook lid support. After confirmed own restoration, managed closed-lid unplug and battery expiry may issue one Sleep request. Ordinary AC-condition endings and cancellation follow macOS. Request acceptance is not actual Sleep proof.
- OS thermal and battery protection, current-owner verification, and recovery of Tether's own state. Foreign assertions/global settings are not forcibly removed; general work remains separate from lid support.
- Advanced automatic triggers can observe selected apps, processes and structured AC task events. Process-bound manual work and `tether run` are no longer provided.
- Optional timer-end notifications and once-per-request expiry warnings (OFF by default). Updates are explicitly installed, with the existing restoration and safe-replacement checks.
- Global hotkeys, rule rehearsal, settings history/rollback and after-work update reservations have been removed to keep the app focused on sleep prevention.
- Compact menu and three Settings tabs, collapsed advanced details, optional display-idle prevention and bounded local diagnostics. Desktop Macs skip helper installation and hide lid/battery options.

Display-idle prevention does not promise unlocked display-off operation, defeat manual locking or change macOS password policy. No automatic unlock, fake input, fan/charging control or guaranteed wake from cable attachment. CPU/transfer conditions are experimental; unverified media/partial-download inference and widgets/Controls remain staged.

[Product contract](docs/PRODUCT-SPEC.ko.md) · [Architecture](docs/ARCHITECTURE-REDESIGN.ko.md) · [Design](DESIGN.md)

## Validation and installation

Current source, isolated integration, live bounded IOKit and native UI results are reported separately in [the P0 evidence report](../../outputs/tether-p0-implementation-20261021/RESULT.ko.md). Installation and physical testing are deferred. UI authorization/AX errors are not counted as passing results. [Earlier V4 records](docs/IMPLEMENTATION-V4-20261015.ko.md) remain historical evidence for their original artifacts.

Physical lid/cable/Sleep/Wake, authenticated remote/display setups, macOS26 hardware and long-term behavior are separate gates. Simulated observations and request acknowledgements do not prove actual Sleep.

General keep-awake work needs no administrator helper. On a MacBook, selecting closed-lid support requires the current helper and normal macOS approval with the lid open. Authentication alone enables neither automatic nor lid work. Desktop Macs require no lid helper. Distribution/update acceptance remains deferred.

[Published releases](https://github.com/jukqaz/tether/releases) · [Installation](docs/INSTALL-AND-TEST.ko.md) · [Release procedure](docs/RELEASING.ko.md)

## Build and test

Use a macOS 26+ SDK and Icon Composer support, Swift 6 and Python 3. Select the compatible Xcode through `xcode-select`. The deployment target is macOS 26; `scripts/build.sh` checks arm64 and the minimum OS of bundled code, including Sparkle.

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/p0-module-cache" \
  python3 scripts/test-p0-automated.py --out .build/verification/p0-<new-run>
```

The native assertion checks own only their test requests and do not put the Mac to sleep. Helper tests use isolated sensor/power fixtures. `sh scripts/build-preview.sh` builds an unprivileged dry-run UI preview, with separate preferences and no production power writes.

[DESIGN.md](DESIGN.md) defines the current palette, Liquid Glass controls, native components, spacing and input behavior for the shipping Settings and menu panel. Follow it when changing UI, and use [automated testing](docs/AUTOMATED-TESTING.ko.md) and [the design review](docs/DESIGN-REVIEW.ko.md) to distinguish source tests, shared-Scene UI tests, installation inspection and physical acceptance. Dated mockups and earlier validation totals are reference history, not the current design or acceptance result.

CLI session commands use a running app of the same version. Examples include `condition ac`, `manual unlimited`, `manual 30m`, `manual +15m`/`+30m`, `manual off`, structured `task` events, `hold`, `sleep`, `doctor`, `diagnose` and `displays`. Removed `run` and `manual --pid` commands are rejected before execution. Extensions and power changes never bypass the request's captured scope or battery ceiling. Use `tether --help` for exact syntax.

Previous records remain in [the changelog](docs/CHANGELOG.ko.md); they are not acceptance evidence for this candidate.
