# chargebar

A small macOS menu bar app for battery charge management on Apple silicon: caps below Apple's 80%, sailing, and a proper "charge to full" for travel. Written for personal use, inspired by AlDente Pro and self-implemented.

> **Status: v0.3.0, personal project.** It works on the author's M4 MacBook Air (Mac16,12) with macOS 26.7.1. It uses private Apple APIs and an undocumented SMC key, so a macOS or firmware update could break it. Use at your own risk.

## Why

Apple's built-in Charge Limit (macOS 26.4+) is good: it's hardware-enforced and survives reboots, but it only offers 80–100%. Battery research (see [RESEARCH.md](RESEARCH.md)) says caps around 75% with shallow cycles roughly add half again as many cycles as an 80% cap. chargebar adds what Apple doesn't offer, and leaves Apple's limit on as a backstop.

## Features

- **Menu bar status:** charge %, state, time to full or empty, health, cycle count, temperature, macOS's current limit, and which hold is stopping the charge (macOS Charge Limit or Optimized Battery Charging).
- **Charge limit picker** (60–100%, or custom) with a cap-vs-cycle-life table shown inline:
  - **80–100%** sets macOS's own Charge Limit. It's hardware-enforced and keeps working when chargebar quits. Values round down to macOS's 5% steps.
  - **Below 80%** is enforced by the optional root helper. macOS holds 80% meanwhile.
- **Sailing:** charge to the cap, let the battery drift down N points (5/10/15/20), then charge back up. This replaces constant tiny top-ups with occasional shallow cycles. The menu shows which way it's going: "charging up to 75%" or "drifting down to 65%".
- **Keep Sailing During Sleep** (opt-in): keeps sailing through system sleep while charge is well above the floor.
- **Charge to Full Now** (travel): pauses sailing and lifts macOS's limit until the battery reaches 100%, then restores both. There's also **Charge Once To** 85/90/95/100%.
- **Copy Diagnostics:** status, raw `pmset` output and the helper's recent events, ready to paste into a bug report.
- No dock icon, launch at login, settings in UserDefaults.

## How it works

| Cap | Mechanism | Needs |
|---|---|---|
| 80–100% | macOS's own Charge Limit, set through PowerUI's private `PowerUISmartChargeClient` (or user-created Shortcuts using the "Set Battery Charge Limit" action), and checked against `pmset -g battlimit` | nothing extra |
| below 80%, or sailing | Root helper switches the charger with SMC key `CHIE`: `0x08` cuts it at the cap, `0x00` reconnects it at the floor | helper install (admin password) |

`CHIE` disconnects the adapter rather than pausing charging. **While the charger is cut, macOS shows the Mac as unplugged and running on battery.** chargebar's menu says "Plugged in, running on battery (charger paused by chargebar)". Apple silicon firmware has no working "pause charging, stay on AC" key (`BCLM`, `CHWA`, `CH0B`/`CH0C` and `CHTE` are all absent on the tested Mac), so a cap below 80% is a sawtooth: cut at the cap, drift to the floor, recharge. A cap below 80% without sailing uses a 3-point band.

### The helper's safety rules

The helper reconnects the charger (`CHIE = 0x00`):
- at startup (including after a crash; launchd restarts it), on exit and on SIGTERM/SIGINT/SIGHUP;
- before system sleep, unless Keep Sailing During Sleep is on and the charge is more than 5 points above the floor;
- at 20% charge or below, and whenever the policy is off or invalid;
- after 5 minutes without a heartbeat from chargebar (time asleep doesn't count).

Every write is read back. Apple's 80% limit stays on as the backstop.

## Install

Requirements: Apple silicon, macOS 26.4 or later (tested on 26.7.1), and Xcode or the Command Line Tools.

```bash
git clone https://github.com/digital-shokunin/chargebar.git
cd chargebar
scripts/build.sh release
cp -R build/Release/chargebar.app /Applications/
open /Applications/chargebar.app

# Optional: the helper, for caps below 80% and sailing (asks for your password)
sudo scripts/install-helper.sh
```

Remove the helper (reconnects the charger and deletes both files):

```bash
sudo scripts/uninstall-helper.sh
```

The release zip contains the same ad-hoc-signed build. macOS Gatekeeper will warn about it; building from source avoids that.

`chargebar.xcodeproj` is also included, for building in Xcode.

## Diagnostics

- **Copy Diagnostics** in the menu.
- Helper events (cuts, reconnects, sleep decisions):
  ```bash
  /usr/bin/log show --last 24h --info --predicate 'subsystem == "net.digital-shokunin.chargebar.helper"'
  ```
  Use the full path: zsh has a `log` builtin that shadows `/usr/bin/log`.
- `tools/` has read-only probes for the SMC charge keys and macOS's charge-limit client, plus the supervised `CHIE` test used during development. See [NOTES.md](NOTES.md).

## Caveats

- **Ad-hoc signing:** builds aren't signed with a Developer ID, so the helper can only check the caller's code-signing *identifier* (`net.digital-shokunin.chargebar`), not a team. Another local program signed with that identifier could drive the helper. The worst case is the charger being cut down to the 20% floor. Signing with a Developer ID and requiring its team would close this.
- **Private APIs:** PowerUI's charge-limit client, and the SMC key `CHIE` on this firmware. Either could change with an update.
- **Optimized Battery Charging** has its own 80% hold, separate from the Charge Limit. chargebar shows when that's the one holding the charge.
- Personal project: no support, no warranty.

## Coming later

Heat protection, manual discharge, calibration cycles and schedules. They appear in the menu as disabled placeholders.

## Battery background

| Cap | Cycles to 80% health | vs 100% |
|---|---|---|
| 100% | ~500 | 1x (baseline) |
| 85% | ~800 | 1.6x |
| 80% | ~1200 | 2.4x |
| 75% | ~1800 | 3.6x |
| 70% | ~2500 | 5x |
| 60% | ~4000+ | 8x |
| 50% (storage) | ~6000+ | 12x |

Cycles are cumulative: 10 partial charges of 10% make 1 cycle. Sitting *at* the cap also ages the battery, but far less than sitting at 100%. A lower cap means longer life and less runtime; 75% is the sweet spot for most mixed use. Sources and reasoning: [RESEARCH.md](RESEARCH.md).

## Prior art

- [AlDente](https://apphousekitchen.com) (feature reference, not code)
- [ProxyBar](https://github.com/baha2046/ProxyBar) (NSStatusItem/AppKit menu patterns)
- Community SMC research on Apple silicon charge keys (e.g. actuallymentor/battery, charlie0129/batt)

## License

MIT. See [LICENSE](LICENSE).
