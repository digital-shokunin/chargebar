# chargebar

macOS menu bar app for battery charge management. AlDente-Pro-tier features, self-implemented.

## Why

Apple's native Charge Limit (macOS 26 on M4 MBA) covers the "cap at 80%" case well — hardware-enforced, persists across reboots. Everything below is what Apple *doesn't* offer.

## Scope

Feature parity target: **AlDente Pro** (not Free — Free's software-only polling is inferior to Apple's native).

### Core
- Sub-80% cap (60 / 65 / 70 / 75) — Apple only offers 80 or 100
- Custom cap % (any integer)
- Hardware-level enforcement via SMC / PMU firmware writes (persists if app quits)

### Pro-tier
- **Sailing mode** — hold at cap, but let battery drift down N% before topping up (fewer charge pulses, LED stays green longer)
- **Manual discharge** — drain to X% for storage or calibration
- **Heat protection** — pause charging above threshold temp
- **Calibration cycle** — periodic full 0→100 cycle to keep gauge accurate (monthly?)
- **Schedule** — time-based cap changes (e.g., 80% weekdays, 100% before a trip)

### GUI
- Cribbed from [ProxyBar](https://github.com/baha2046/ProxyBar) — Swift + NSStatusItem + AppKit menu patterns
- Consistent with `crabbyproxy` styling if that's home-grown
- Small, opinionated, no dock icon

### In-app guidance (UX requirement)

When user opens the cap picker, render this reference table inline so the tradeoff is visible at the point of decision. Highlight the currently-selected row.

| Cap | Cycles to 80% health | vs 100% |
|---|---|---|
| 100% | ~500 | 1x (baseline) |
| 85% | ~800 | 1.6x |
| 80% | ~1200 | 2.4x |
| 75% | ~1800 | 3.6x |
| 70% | ~2500 | 5x |
| 60% | ~4000+ | 8x |
| 50% (storage) | ~6000+ | 12x |

Copy to show next to the table:
> Cycles are cumulative — 10 partial charges of 10% = 1 cycle. Sitting *at* the cap also ages the battery, but far less than sitting at 100%. Lower cap = longer life, less runtime. 75% is the sweet spot for most mixed use.

Source data: see `RESEARCH.md`.

## Non-goals
- Windows/Linux
- Intel Mac support (Apple silicon only — M-series SMC/PMU APIs)
- Free/paid tier split — this is personal use

## Prior art / references
- AlDente Pro (apphousekitchen) — feature reference, not code
- ProxyBar — GUI code patterns
- Apple's private `IOPMFamily` / `AppleSmartBattery` interfaces
- SMC keys `BCLM`, `CHWA`, `CH0I` (Intel legacy — need Apple silicon equivalents)

## Environment
- macOS 26.5.2+ on Apple silicon M-series
- Swift 6, Xcode 16+
- Menu bar app (LSUIElement in Info.plist)

## Status
v0.2: drives macOS's own Charge Limit (80–100). Caps below 80 and sailing are not enforced yet.

Live:
- Status item: battery SF Symbol + charge %, updated via IOPowerSources notifications plus a 60 s refresh
- Details: charge, state, time to full or empty, health, cycles, temperature, why macOS isn't charging, and macOS's current limit (from `pmset -g battlimit`)
- Charge limit picker (60–100 and custom) with the cap-vs-cycle-life table inline. 80–100 sets macOS's Charge Limit through PowerUI's private `PowerUISmartChargeClient`, checked afterwards against `pmset`. Custom values round down to macOS's 5% steps.
- Charge to Full Now (travel) and Charge Once To 85/90/95/100
- Launch at login (SMAppService), settings in UserDefaults

Not yet enforced:
- Caps below 80 and sailing are labelled "needs sailing helper"; macOS holds 80% meanwhile. The plan is a root helper using SMC key `CHIE` (see NOTES.md).
- Heat protection, manual discharge, calibration, schedule: disabled menu placeholders

Build: see NOTES.md (`xcodebuild` with Xcode.app, or `scripts/build.sh` with Command Line Tools only).
