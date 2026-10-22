# Notes

## Building

Two equivalent paths over the same sources in `chargebar/`:

| Path | Needs | Command |
|---|---|---|
| Xcode project | Xcode.app (26+) selected with `xcode-select` | `xcodebuild -project chargebar.xcodeproj -scheme chargebar -configuration Debug -derivedDataPath build/xcode build` |
| Script | Command Line Tools only | `scripts/build.sh` (Debug) / `scripts/build.sh release` |

Both produce an arm64, macOS 26.0+, Swift 6 (strict concurrency), hardened-runtime, ad-hoc-signed app. `scripts/build.sh` writes to `build/<Config>/chargebar.app`.

`chargebar.xcodeproj` is hand-written (no xcodegen). Source files are listed explicitly, so a new `.swift` file must be added in Xcode (or to `project.pbxproj`); `scripts/build.sh` picks up `chargebar/*.swift` automatically.

Self-test (Debug builds only): prints the status item and the full menu tree, then exits.

```
CHARGEBAR_SELFTEST=1 build/Debug/chargebar.app/Contents/MacOS/chargebar
```

## Enforcement on Apple silicon (not implemented)

v1 ships `LoggingChargeController`, which logs requests and writes nothing. A real `ChargeController` needs the following.

### What this machine reports (read-only `ioreg -rn AppleSmartBattery`, `pmset -g batt`, 2026-10-14)

- Mac16,12 (M4 MacBook Air), macOS 26.7.1, gas gauge `bq40z651`, 3S pack.
- `DesignCapacity` 4629 mAh, `NominalChargeCapacity` 4409 (95%), `AppleRawMaxCapacity` 4282, `CycleCount` 59, `DesignCycleCount9C` 1000.
- `Temperature` 3055 (hundredths of °C = 30.55 °C), `VirtualTemperature` 3229.
- Sitting at 80% on a 100 W PD adapter: `IsCharging = No`, `FullyCharged = No`, `ChargerData.NotChargingReason = 0x01000000`, `ChargerInhibitReason = 0`, `ChargingCurrent = 0`, `ChargingVoltage = 4262` (per cell, mV).
  This looks like Apple's native 80% Charge Limit holding the pack. When a third-party inhibit is active, `NotChargingReason` should change, which makes it a useful signal for verifying our own writes.
- `pmset -g` exposes no charge-limit setting. Apple's limit lives in firmware/powerd, not in pmset.

### Pieces needed

1. **Privileged helper.** SMC writes need root. Plan: a launchd daemon registered with `SMAppService.daemon(plistName:)`, which the user approves in System Settings › Login Items. The app talks to it over XPC (`NSXPCConnection` with a code-signing requirement on both sides). The helper must keep enforcing when the app is not running, and it needs a stable signing identity. Ad-hoc signing won't do, so this step requires a Developer ID / team.
2. **SMC access.** Open an `AppleSMC` user client (`IOServiceOpen` + `IOConnectCallStructMethod`, the selector/struct layout used by smcFanControl, AlDente, and actuallymentor/battery) to read/write 4-char keys.
3. **Keys.** See "SMC probe results" below. Of the keys other tools use, only `CHIE` exists on this machine.
4. **Control loop in the helper.** With no hardware cap register, the helper polls (or listens to IOPS notifications) and sets inhibit when charge reaches the cap. For sailing, it clears inhibit once charge falls to `cap - drift`. Heat protection is the same loop gated on `Temperature`. Manual discharge sets the adapter-disable key until the target is reached. On sleep, the inhibit state must hold or be re-asserted on wake (`IORegisterForSystemPower`), or the pack charges to 100% overnight.
5. **Coexistence with Apple's Charge Limit.** When the native 80% limit is on and our cap is ≥ 80, there's nothing to do. For caps below 80, the helper inhibits earlier, and the native limit remains a backstop. Detect and display which mechanism is currently holding the pack.
6. **Verification.** After every write, read back the key and confirm `IsCharging`, `ChargerData.NotChargingReason` and `InstantAmperage` change as expected within a few seconds. If they don't, mark enforcement as failed in the menu rather than claiming it works.
7. **Safety.** On helper exit, uninstall, or crash, clear inhibit and adapter-disable (fail open to normal charging). Never leave adapter-disable set across a reboot.

### SMC probe results (2026-10-14, Mac16,12, macOS 26.7.1, read-only)

`tools/smc-probe.c` is a read-only AppleSMC client. It only issues the read-key, key-info and key-from-index commands, and refuses anything else. It ran as a normal user, with no root and no writes.

```
clang -O2 -framework IOKit -o build/smc-probe tools/smc-probe.c
build/smc-probe          # charge-related keys
build/smc-probe --all    # all 2265 keys
```

| Key | Present | Type / size | Attr | Current value | Community meaning |
|---|---|---|---|---|---|
| `BCLM` | no | | | | Intel charge-level max |
| `CHWA` | no | | | | Intel 80% flag |
| `CH0B`, `CH0C` | no | | | | charge inhibit (older Apple silicon firmware) |
| `CHTE` | **no** | | | | charge inhibit (macOS 15.7+ per `battery` CLI) |
| `CH0I`, `CH0J`, `CH0K` | no | | | | adapter disable / discharge (older firmware) |
| `CHIE` | **yes** | `hex_` / 1 | 0xd4 | `00` | adapter disable / force discharge (newer firmware) |
| `ACLC` | yes | `ui8` / 1 | 0xd4 | `03` | MagSafe LED colour |
| `CHNC` | yes | `hex_` / 8 | 0x94 | `00000001 00000000` | first u32, read little-endian, is 0x01000000, the same as ioreg `NotChargingReason`. Read-only mirror, so it can verify inhibit. |

Observations:
- Attr bit 0x40 is commonly read as "writable". Among the `CH*` charger keys, **only `CHIE` has it**. 298 keys overall have it (`AC-*`, `D*`, `MB*`, `bm*`, `r*`, ...).
- The charge-inhibit keys other tools rely on (`CH0B`/`CH0C`/`CHTE`) are absent on this firmware. Apple's native Charge Limit (holding at 80% now) is implemented somewhere that isn't exposed as a writable `CH*` key, probably powerd talking to the PMU.
- So the one known lever is `CHIE`. Community reports say writing `0x08` disconnects the adapter (forces discharge) and `0x00` restores it. Whether any `CHIE` value inhibits charging *without* also running the system from battery is unknown on this machine.

### Implications

- **Manual discharge and calibration** have a plausible path via `CHIE`.
- **A sub-80% cap and sailing** have no confirmed inhibit key. Options, in order of preference:
  1. Find how powerd applies the native Charge Limit (private preference or IOPM call). If the target is settable to arbitrary values, that is the cleanest path. It needs research into powerd and `IOPMFamily`; no SMC writes.
  2. Emulate an inhibit with `CHIE`: pulse the adapter off at the cap and back on at the floor. This works, but runs from battery while "inhibited", which costs cycles. It fits sailing, not a fixed hold.
  3. Test other `CHIE` bit values for an inhibit-only effect. That is an experimental hardware write, and needs the owner's explicit go-ahead.
- Any write needs root: a privileged helper, or a one-off `sudo` test binary for experiments. Verify every write with `CHIE` read-back, ioreg `IsCharging` / `NotChargingReason` / `InstantAmperage`, and `CHNC`.

### How macOS holds its own Charge Limit (2026-10-14, read-only research)

- **Owner:** `powerd`. The active policy is persisted in `/Library/Preferences/com.apple.powerd.charging.plist` as an NSKeyedArchiver blob under `policies`. On this Mac it decodes to one `ChargeCtrlPolicy`: `reason = manualChargeLimit`, `soclimit = 80`, `drain = true`, `noChargeToFull = false`, `isEndOfCharge = true`, `owner = <PID of the setting process>`, plus a token UUID. `pmset` doesn't expose it.
- **Client API:** private but exported by IOKit, in `IOKit.tbd` with no header:
  - `IOPSLimitBatteryLevel(token, uint8 soc, flags, CFStringRef reason)`. The flags are bit0 drain, bit1 noChargeToFull, bit2 isEndOfCharge. It sends XPC to `com.apple.iokit.powerdxpc` with key `chargeSocLimit` and `chargeSocLimitAction = 3`. Decoded from the disassembly.
  - Also `IOPSLimitBatteryLevelRegister`, `IOPSLimitBatteryLevelCancel`, `IOPSCopyBatteryLevelLimits` and `IOPSCopyChargeStatus`.
  - The SoC argument is a full byte, so the protocol isn't limited to 80/100. Whether powerd clamps the value is unknown.
- **Gate:** powerd carries and checks `com.apple.private.iokit.soc-limit`. The System Settings Battery pane (`PowerPreferences.appex`) doesn't call powerd directly; it goes through PowerUI smart charging (`com.apple.powerui.smartcharging` entitlement). Both are Apple-private entitlements. An ad-hoc or Developer ID app can't carry them unless SIP/AMFI is relaxed, so chargebar can't call this path as a normal app. Not verified by calling it: that would change the setting if the gate isn't enforced.
- **Settings UI strings:** `DeviceSupports80ChargeLimit`, `ChargeLimitSlider`, `chargeLimitLevel`. The pane only offers 80/100 on this hardware.
- **No AlDente traces** (prefs, containers, logs) remain to show how it held a cap on this machine.
- `ioreg` `BatteryData.DailyMaxSoc` / `DailyMinSoc` (79 / 20) are gas-gauge statistics, not settings.

### Enforcement paths

| Path | Holds below 80? | Survives app quit/reboot | Needs | Verdict |
|---|---|---|---|---|
| A. powerd SoC limit via `IOPSLimitBatteryLevel` | likely (any byte) | yes (powerd persists it) | private entitlement, effectively SIP/AMFI off | blocked for a normal app |
| B. Rewrite `com.apple.powerd.charging.plist` as root, then restart powerd | unknown | maybe; powerd may discard or rewrite it | admin; unsupported, fragile | experiment only |
| C. `CHIE` adapter cut, driven by a root helper | yes, as a sawtooth (cap → floor) | helper must re-assert after reboot | admin to install a LaunchDaemon; helper can be ad-hoc signed for personal use (a team is only needed for `SMAppService.daemon` / distribution) | **recommended** |
| D. Apple's 80% toggle (travel mode) | n/a | yes | no API for third parties; UI scripting needs Accessibility, or deep-link the user to Settings | open the Battery pane and ask |

Recommended hybrid: keep Apple's 80% limit on as the backstop, so the pack never goes past 80 even if chargebar dies. A small root helper implements cap and sailing: cut the adapter with `CHIE` at the cap, reconnect at the floor. Fail-safe rules:
- The helper restores `CHIE = 00` on exit or SIGTERM, and when the app is uninstalled.
- launchd runs it with KeepAlive.
- If it can't verify state, it fails open, back to normal charging.
- Before relying on any of this, check whether `CHIE` survives sleep and reboot.

Proposed first hardware test (needs the owner's explicit go-ahead and one admin prompt):
1. Read `CHIE`.
2. Write `0x08`.
3. Within 10 s, confirm in ioreg that `ExternalConnected` stays Yes and `InstantAmperage` goes negative (running on battery while plugged in).
4. Write `0x00`.
5. Confirm read-back and that the adapter is drawing again.
6. If any step fails, restore `0x00` immediately.

### Follow-up probes (2026-10-14)

- macOS here is **26.7.1** (`sw_vers`). System firmware 20457.1.29, OS loader 18000.161.10.701.1.
- `pmset -g battlimit` (no root) lists powerd's SoC policies: one terminated and one active `manualChargeLimit` at `chargeSocLimitSoc = 80`, drain on, EOC on. chargebar can read this to display Apple's limit.
- Firmware band keys `bfD0` (ui32), `bfE0` (ui32) and `bfF0` (ui8) exist, attr 0xd4, and are readable as a normal user. All are **0**, so Apple's 80% hold does not use them. Write access is reported to return `kIOReturnNotPrivileged` even as root on this firmware generation (charlie0129/batt #152). Not tested here.
- `CH0B` / `CH0C` / `CHTE` are not in the key index at all (key-info fails), rather than present with zero size.
- `PowerUISmartChargeClient` (PowerUI.framework, private) has `initWithClientName:`, `isMCLSupported`, `isMCLCurrentlyEnabled:`, `getMCLLimitWithError:`, `availableChargeLimitsWithError:`, `currentChargeLimit:`, `setMCLLimit:error:`, `enableMCL:`, `disableMCL:`, `temporarilyDisableMCL:` and `temporarilyOverrideMCLTargetSoC:error:`. This is the no-root path other tools use for Apple's 80–100 limit and for "charge to full now" (travel mode). The getter-only probe is `tools/mcl-read.m`. Verified by running it (see below).
- `com.apple.smartcharging.topoffprotection` is not readable as a user (root-only domain).

### macOS Charge Limit control (2026-10-14, verified on 26.7.1)

- `tools/mcl-read.m` output: `isMCLSupported 1`, `isMCLCurrentlyEnabled 1`, `getMCLLimit 80`, `availableChargeLimits (80, 85, 90, 95, 100)`, `currentChargeLimit 100`. The private client works for a normal-user, ad-hoc-signed process, with no entitlement needed for reads. Writes go through the same client and are checked against `pmset -g battlimit` after each change.
- chargebar uses it in `MacOSChargeLimitController` via `SmartChargeClient` (dlopen + ObjC runtime, no private headers). PowerUI is loaded only when the user changes a setting, never at launch.
- **Sanctioned alternative:** Shortcuts action "Set Battery Charge Limit" (`SetBatteryChargeLimitAction` in ActionKit, macOS 26.4+). Parameters: `limit` (a `ChargeLimit` entity) and `setUntilTomorrow` (Bool, for travel). The user builds or approves the shortcut once in Shortcuts. chargebar could then call `/usr/bin/shortcuts run <name>`. This is the only user-consented, public route; there is no permission prompt an app can request for the charge limit itself. Reportedly a lifted limit comes back at 6 AM.
- Shortcuts action details (ActionKit metadata): `limit` is a `ChargeLimit` entity from `ChargeLimitsQuery` (80/85/90/95/100) with **no resolvable input types**, so it can't be fed a number from shortcut input; one shortcut per value is needed. `setUntilTomorrow` (Bool) resets the limit the following day. Generating or signing `.shortcut` files programmatically isn't reliable (undocumented serialization; `shortcuts sign` needs iCloud), so the user creates them. chargebar (`ChargeLimitShortcuts`) uses `chargebar limit <N>` / `chargebar charge to full` when `shortcuts list` shows them, otherwise the private client. Untested so far: whether `shortcuts run` of that action runs headlessly without a prompt.

### CHIE test result (2026-10-21, `sudo build/chie-test`)

| | CHIE | DC-in (PDTR) | Battery (PPBR) | B0AC | Source | ExternalConnected |
|---|---|---|---|---|---|---|
| before | 0x00 | 15.67 W | 0.94 W | 0 mA | AC Power | 1 |
| t+2..10 s | 0x08 | 0.15–0.18 W | 8.5–14.0 W | −706…−1131 mA | Battery Power | **0** |
| after restore | 0x00 | 20.61 W | 0.83 W | 0 mA | AC Power | 1 |

- **CHIE = 0x08 disconnects the adapter**, taking effect in under 2 s and reversing cleanly. Read-back was correct both ways.
- macOS reports the Mac as **unplugged** (`ExternalConnected = 0`, source "Battery Power"), not as "plugged in, not charging". Battery-power behaviour (energy settings, battery menu, low-power prompts) applies while it's set.
- CHIE is a *discharge* switch, not a charge inhibit. It can't hold a steady charge below 80 while running on AC. Consequences for the helper:
  - **Sailing** maps directly: at the cap, set 0x08 and drain to the floor; at the floor, set 0x00, and macOS charges back up, with its 80% limit as the backstop.
  - A **fixed sub-80 cap without sailing** is the same loop with a small band (e.g. cap−3%), to avoid rapid toggling.
  - **Manual discharge** and **calibration** also map directly.
- Not yet known: whether 0x08 survives sleep or reboot. The helper resets it at startup and on wake regardless.

### Sailing helper (2026-10-21)

- Files: `helper/chargebar-helper.c` (C, root), `helper/net.digital-shokunin.chargebar.helper.plist` (LaunchDaemon: KeepAlive, Mach service `net.digital-shokunin.chargebar.helper`), `scripts/install-helper.sh` / `scripts/uninstall-helper.sh`, app side in `chargebar/HelperClient.swift`.
- Channel: plain libxpc Mach service. The helper only accepts peers matching `identifier "net.digital-shokunin.chargebar"` (`xpc_connection_set_peer_code_signing_requirement`). With ad-hoc signing that's an identifier check, not a team check: any local process signed with that identifier could set the policy. The worst case is the charger being cut down to the 20% floor. Acceptable for personal use; a Developer ID team requirement would close it.
- Policy: `{op: policy, enabled, cap, floor}`. Cut at charge ≥ cap, reconnect at ≤ floor, leave it alone in between. A cap below 80 without sailing uses a 3-point band. Sailing works at any cap below 100. macOS's own limit stays at max(80, cap) as the backstop.
- Fail-safe reconnects: startup, exit/atexit, SIGTERM/SIGINT/SIGHUP, system sleep, policy off or invalid, no heartbeat for 300 s, charge ≤ 20%, CHIE or battery unreadable. Every write is read back.
- Re-evaluates on IOPS power-source notifications, every 30 s, and on wake.
- Logs: `log show --predicate 'subsystem == "net.digital-shokunin.chargebar.helper"' --info`.
