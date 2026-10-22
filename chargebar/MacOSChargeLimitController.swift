import Foundation
import os

/// Drives macOS's own Charge Limit, and verifies every change by reading the
/// powerd policy back with `pmset -g battlimit`.
///
/// Prefers the user's own Shortcuts (`ChargeLimitShortcuts`, user-consented);
/// falls back to PowerUI's private client (`SmartChargeClient`).
///
/// - Caps 80–99: macOS limit on, set to the cap. Hardware-enforced, survives
///   chargebar quitting.
/// - Cap 100: macOS limit off.
/// - Caps below 80, and sailing: enforced by the root helper (`HelperClient`),
///   which cuts the charger at the cap and reconnects it at the floor. macOS's
///   limit stays at 80 as the backstop.
@MainActor
final class MacOSChargeLimitController: ChargeController {
    static let lowestNativeLimit = 80

    let name = "macOS Charge Limit"

    private let log = Logger(subsystem: "net.digital-shokunin.chargebar", category: "ChargeController")
    private var client: SmartChargeClient?
    private var requestedCap: Int?
    private var sailingFloor: Int?
    private var verification: String?
    private var lastRoute: String?
    var onVerified: ((_ ok: Bool, _ message: String) -> Void)?

    /// Band used for a cap below 80 without sailing, so the charger isn't toggled constantly.
    static let fixedCapBand = 3

    private let helper = HelperClient()
    private var heartbeat: Timer?

    init(initialCap: Int? = nil, initialSailingFloor: Int? = nil) {
        requestedCap = initialCap
        sailingFloor = initialSailingFloor
        pushHelperPolicy()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pushHelperPolicy() }
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeat = timer
    }

    /// Called when the helper reports a new state (e.g. charger cut / reconnected).
    var onHelperUpdate: (() -> Void)? {
        get { helper.onUpdate }
        set { helper.onUpdate = newValue }
    }

    /// The band the helper should enforce: always for sailing, and for caps below 80
    /// (macOS alone handles a plain cap of 80+). nil when the helper isn't needed.
    private var helperBand: (cap: Int, floor: Int)? {
        guard let cap = requestedCap, cap < 100, sailingFloor != nil || cap < Self.lowestNativeLimit else { return nil }
        let floor = sailingFloor ?? (cap - Self.fixedCapBand)
        return (cap, max(floor, 20))
    }

    /// Sends the current policy (also the heartbeat). Disables the helper when not needed.
    private func pushHelperPolicy() {
        guard HelperClient.isInstalled else { return }
        if let band = helperBand {
            helper.sendPolicy(enabled: true, cap: band.cap, floor: band.floor)
        } else {
            helper.sendPolicy(enabled: false, cap: 0, floor: 0)
        }
    }

    /// macOS accepts 80–100 in 5% steps; round down so the hold is never above the cap.
    static func nativeLimit(for cap: Int) -> Int {
        max(lowestNativeLimit, min(100, cap / 5 * 5))
    }

    func setLimit(_ percent: Int) throws {
        requestedCap = percent
        let before = MacOSLimit.read()
        let native = percent >= 100 ? 100 : Self.nativeLimit(for: percent)
        let shortcut = ChargeLimitShortcuts.name(forLimit: native)
        if ChargeLimitShortcuts.installed().contains(shortcut) {
            try ChargeLimitShortcuts.run(shortcut)
            lastRoute = "Shortcuts"
        } else {
            let client = try loadClient()
            if native >= 100 {
                try client.disable()
            } else {
                // enableMCL resets the target to 80, so enable only when off, and before setting.
                if MacOSLimit.read() == .off { try client.enable() }
                try client.setLimit(native)
            }
            lastRoute = "built-in client"
        }
        let expected: MacOSLimit = native >= 100 ? .off : .on(native)
        log.info("setLimit(\(percent, privacy: .public)) -> macOS \(String(describing: expected), privacy: .public)")
        verify(expected, before: before)
        pushHelperPolicy()
    }

    func setSailing(floor: Int?) throws {
        sailingFloor = floor
        log.info("setSailing(floor: \(floor.map(String.init) ?? "off", privacy: .public))")
        pushHelperPolicy()
    }

    func chargeToFullNow() throws {
        if ChargeLimitShortcuts.installed().contains(ChargeLimitShortcuts.chargeToFull) {
            // Shortcut sets 100% "until tomorrow"; macOS restores the previous limit the next day.
            try ChargeLimitShortcuts.run(ChargeLimitShortcuts.chargeToFull)
            lastRoute = "Shortcuts"
            verification = "Charging to full; macOS restores the limit tomorrow"
        } else {
            try loadClient().temporarilyDisable()
            lastRoute = "built-in client"
            verification = "Charging to full for this charge"
        }
        log.info("chargeToFullNow via \(self.lastRoute ?? "?", privacy: .public)")
    }

    func chargeOnce(to percent: Int) throws {
        try loadClient().overrideTarget(percent)
        log.info("chargeOnce(to: \(percent, privacy: .public))")
        verification = "Charging once to \(percent)%"
    }

    func status() -> ChargeControllerStatus {
        if let band = helperBand {
            let mode = sailingFloor != nil ? "sailing \(band.cap)/\(band.floor)" : "cap \(band.cap)% (band \(band.floor)\u{2013}\(band.cap))"
            let summary: String
            if !HelperClient.isInstalled {
                summary = "\(mode) needs the helper (sudo scripts/install-helper.sh); macOS holds 80%"
            } else if let error = helper.lastError {
                summary = "\(mode): helper \(error); macOS holds 80%"
            } else if let status = helper.lastStatus {
                summary = "\(mode) (" + (status.isCutting ? "charger cut by chargebar" : "charging") + ")"
            } else {
                summary = "\(mode) (waiting for helper)"
            }
            return ChargeControllerStatus(summary: summary, detail: verification)
        }
        var summary = "macOS Charge Limit"
        if let cap = requestedCap, cap < 100, Self.nativeLimit(for: cap) != cap {
            summary += " (\(cap)% rounded to \(Self.nativeLimit(for: cap))%)"
        }
        if let lastRoute { summary += " via \(lastRoute)" }
        return ChargeControllerStatus(summary: summary, detail: verification)
    }

    // MARK: -

    private func loadClient() throws -> SmartChargeClient {
        if let client { return client }
        let new = try SmartChargeClient()
        guard new.isSupported else { throw SmartChargeClient.Failure.unavailable("isMCLSupported = false") }
        client = new
        return new
    }

    /// powerd applies policy changes asynchronously; check after a short delay.
    private func verify(_ expected: MacOSLimit, before: MacOSLimit) {
        verification = "Verifying\u{2026}"
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            let actual = MacOSLimit.read()
            guard let self else { return }
            if actual == expected || (expected == .off && actual == .on(100)) {
                let message = actual == before ? "already \(actual.label)" : "changed \(before.label) \u{2192} \(actual.label)"
                self.verification = "macOS limit \(message)"
                self.onVerified?(true, message)
            } else {
                let message = "not applied: expected \(expected.label), powerd reports \(actual.label)"
                self.verification = "macOS limit \(message)"
                self.onVerified?(false, message)
                self.log.error("verify failed: expected \(expected.label, privacy: .public), got \(actual.label, privacy: .public)")
            }
        }
    }
}

/// macOS's own Charge Limit as powerd reports it.
enum MacOSLimit: Sendable, Equatable {
    case unknown
    case off
    case on(Int)

    var label: String {
        switch self {
        case .unknown: return "unknown"
        case .off: return "off"
        case .on(let soc): return "\(soc)%"
        }
    }

    /// Parses `pmset -g battlimit`: the active (non-terminated) manualChargeLimit
    /// policy, if any. Runs a short-lived pmset process; no root needed.
    nonisolated static func read() -> MacOSLimit {
        rawOutput().map(parse) ?? .unknown
    }

    /// Raw `pmset -g battlimit` output, or nil if pmset fails.
    nonisolated static func rawOutput() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "battlimit"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The active Optimized Battery Charging hold (a separate powerd policy), if any.
    nonisolated static func optimizedHold(_ text: String) -> Int? {
        entries(text)?.first {
            ($0["Terminated"] as? String) == "0" && ($0["chargeSocLimitReason"] as? String) == "optimizedBatteryCharging"
        }.flatMap { ($0["chargeSocLimitSoc"] as? String).flatMap(Int.init) }
    }

    private nonisolated static func entries(_ text: String) -> [[String: Any]]? {
        guard let start = text.firstIndex(of: "("),
              let plist = try? PropertyListSerialization.propertyList(from: Data(text[start...].utf8), format: nil)
        else { return nil }
        return plist as? [[String: Any]]
    }

    nonisolated static func parse(_ text: String) -> MacOSLimit {
        // Output: "Battery level limits:\n( { key = value; ... }, ... )" (OpenStep plist).
        guard let entries = entries(text) else { return .unknown }

        let active = entries.last {
            ($0["Terminated"] as? String) == "0" && ($0["chargeSocLimitReason"] as? String) == "manualChargeLimit"
        }
        guard let active else { return .off }
        guard let soc = (active["chargeSocLimitSoc"] as? String).flatMap(Int.init) else { return .unknown }
        return .on(soc)
    }
}
