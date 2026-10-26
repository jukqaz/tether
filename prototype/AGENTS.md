# Prototype Instructions

The 2026-10-26 follow-up requires complete Korean and English copy plus System/Light/Dark appearance selection. Locale and appearance changes must preserve current settings, selected policies, timers and pause state. Verify both locales across both themes, including expanded details and scroll ends. Update UX separates checking from installation; show current version/build, last check, channel and result states. Never auto-install, restart, introduce deferred-install scheduling, or claim a real update succeeded from fixture UI.

Tether design-only state and scroll review. Match the selected `power-only-*-v2.png` images in the parent directory. Preserve three settings tabs: 잠자기 방지 / 전원 동작 / 앱 설정. Automatic behavior is power connection/disconnection only; battery starts are manual. All Stop blocks new manual starts until explicitly allowed; protection cannot be bypassed. Never control macOS power, lock, helpers, installed apps or edit the actual Tether repository. All data here is fixture data. Keep Korean wording concise, Mac-sized controls, graphite/blue, glass only in chrome/control surfaces. Sources in this prototype must remain isolated from application source and installed binaries.

Run the local server yourself and open the preview in the browser available to this environment. Do not give the user server-start instructions when you can run it.

Before making substantial visual changes, use the Product Design plugin's `get-context` skill when the visual source is unclear or no longer matches the current goal. When the user gives durable prototype-specific design feedback, preferences, or decisions, record them in `AGENTS.md`.

When implementing from a selected generated mock, treat that image as the source of truth for layout, component anatomy, density, spacing, color, typography, visible content, and hierarchy.

Build app UI in `src/`. Keep `.openai/hosting.json`, `worker/index.js`, `scripts/prepare-sites-build.mjs`, and `tests/sites-worker.test.mjs` intact so the same local prototype can be handed to Sites. Before a Sites handoff, run `npm run build` and `npm run test:sites`; the build must leave `dist/client/index.html`, `dist/server/index.js`, and `dist/.openai/hosting.json`.

The final review fixes use shared preview-state invariants at every model entry point. Automatic OFF cancels a pending automatic pause; ON can start a fresh valid AC automatic session. Power, protection, session, recording or release changes invalidate update preparation even when General is closed; only explicit confirm-to-preparing may atomically end sessions while retaining preparation. Protection text distinguishes the stop-event snapshot from a changed current safety limit. Preserve these behaviors in both Korean and English.
