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
/// - Caps below 80: macOS limit held at 80 as a backstop. The lower cap needs
///   the CHIE sailing helper (TODO, see NOTES.md).
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

    init(initialCap: Int? = nil) {
        requestedCap = initialCap
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
    }

    func setSailing(floor: Int?) throws {
        // TODO: hand to the CHIE helper once it exists. macOS's limit has no sailing mode.
        sailingFloor = floor
        log.info("setSailing(floor: \(floor.map(String.init) ?? "off", privacy: .public)) recorded; needs sailing helper")
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
        var summary = "macOS Charge Limit"
        if let cap = requestedCap, cap < Self.lowestNativeLimit {
            summary = "\(cap)% needs sailing helper; macOS holds 80%"
        } else if let cap = requestedCap, cap < 100, Self.nativeLimit(for: cap) != cap {
            summary += " (\(cap)% rounded to \(Self.nativeLimit(for: cap))%)"
        } else if sailingFloor != nil {
            summary += "; sailing needs helper"
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
