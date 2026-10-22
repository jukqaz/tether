# Tether

A menu-bar app for keeping Apple Silicon Macs working, with optional closed-lid support on MacBooks. [한국어 안내](README.ko.md)

**Local candidate58 · macOS26+ · designv4.** This ad-hoc signed development candidate implements the approved design. It has not replaced the installed app or been published in this work. [Implementation and evidence](docs/IMPLEMENTATION-V4-20261015.ko.md).

## Features

- AC-only automatic work, with either basic power detection or advanced AND/OR condition groups. New installations default to automatic OFF and lid support OFF independently.
- Timed or unlimited manual work on AC; battery work is capped at two hours from its first start. Explicit +15/+30-minute extensions must fit in full under the original battery ceiling.
- Every AC departure ends prior automatic, manual and task-event requests, including a battery-origin request that visited AC. No continuation reservation or replay of old work.
- Optional MacBook lid support. After confirmed own restoration, managed closed-lid unplug and battery expiry may issue one Sleep request. Ordinary AC-condition endings and cancellation follow macOS. Request acceptance is not actual Sleep proof.
- OS thermal and battery protection, current-owner verification, and recovery of Tether's own state. Foreign assertions/global settings are not forcibly removed; general work remains separate from lid support.
- Process-bound manual work, approval-before-execution `tether run`, structured AC task events, and selected-condition observation.
- No-effects rule rehearsal, exact-candidate after-work update reservation, bounded settings history/selective rollback, and optional once-per-request expiry warnings (OFF by default).
- Compact menu and three Settings tabs, collapsed advanced details, optional display-idle prevention and bounded local diagnostics. Desktop Macs skip helper installation and hide lid/battery options.

Display-idle prevention does not promise unlocked display-off operation, defeat manual locking or change macOS password policy. No automatic unlock, fake input, fan/charging control or guaranteed wake from cable attachment. CPU/transfer conditions are experimental; unverified media/partial-download inference and widgets/Controls remain staged.

[Product contract](docs/PRODUCT-SPEC.ko.md) · [Architecture](docs/ARCHITECTURE-REDESIGN.ko.md) · [Design](DESIGN.md)

## Validation and installation

[Final automation](.build/verification/v4-implementation-20261015/automated-accepted-v4/summary.json): 49 steps passed, zero failures or source changes during execution. The 1,127-source-test run initially skipped two CLI cases requiring the packaged executable; both passed in the package run. Packaged helper105+v4 14 cases, 63 simulated installer cases and ten isolated upgrades using the actual previous build56 helper are included, not additional unique-feature totals.

34 offscreen native renders were reviewed. Actual private native UI runs passed 15 of 24 unique paths; the nine corrected paths still need verification because the next run was interrupted by the locked Mac session. Subsequent changes are limited to fixture observations and accessibility metadata; power policy, helper and CLI continuity is recorded separately. Installation, physical lid/cable/Sleep/Wake, authenticated remote/display setups, macOS26 hardware and long-term performance remain separate acceptance gates. The host was macOS27.0.1; simulated sensors and command acknowledgements are not physical proof.

[Detailed results and screenshots](docs/IMPLEMENTATION-V4-20261015.ko.md) · [Acceptance checklist](docs/VALIDATION-CHECKLIST.ko.md) · [Deferred installation and physical actions](docs/V4-PHYSICAL-CHECKLIST.ko.md)

The installed app and published download may differ. MacBooks require normal macOS helper approval with the lid open; preparation does not enable automatic or lid work. Desktop Macs do not require this helper. Stable and Stable + Beta channels remain available; actual distribution/update acceptance is deferred.

[Published releases](https://github.com/jukqaz/tether/releases) · [Installation](docs/INSTALL-AND-TEST.ko.md) · [Release procedure](docs/RELEASING.ko.md)

## Build and test

Use a macOS 26+ SDK and Icon Composer support, Swift 6 and Python 3. Select the compatible Xcode through `xcode-select`. The deployment target is macOS 26; `scripts/build.sh` checks arm64 and the minimum OS of bundled code, including Sparkle.

```sh
python3 scripts/test-automated.py
# Optional observed OS timeout for a finite test assertion
python3 scripts/test-automated.py --native-expiry
```

The native assertion checks own only their test requests and do not put the Mac to sleep. Helper tests use isolated sensor/power fixtures. `sh scripts/build-preview.sh` builds an unprivileged dry-run UI preview, with separate preferences and no production power writes.

[DESIGN.md](DESIGN.md) defines the current palette, Liquid Glass controls, native components, spacing and input behavior for the shipping Settings and menu panel. Follow it when changing UI, and use [automated testing](docs/AUTOMATED-TESTING.ko.md) and [the design review](docs/DESIGN-REVIEW.ko.md) to distinguish source tests, shared-Scene UI tests, installation inspection and physical acceptance. Dated mockups and earlier validation totals are reference history, not the current design or acceptance result.

CLI session commands use a running app of the same version. Supported commands include `condition ac`, `manual unlimited`, `manual 30m`, `manual +15m`/`+30m`, `manual off`, PID-bound manual work, `run`, structured `task` events, `hold`, `sleep`, `doctor`, `diagnose` and `displays`. Automatic battery conditions and unplug continuation are retired. Use `tether --help` for exact syntax.

Previous records remain in [the changelog](docs/CHANGELOG.ko.md); they are not acceptance evidence for this candidate.
