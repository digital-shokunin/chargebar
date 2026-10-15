import Foundation

/// Point-in-time view of the internal battery, merged from IOPowerSources and
/// the AppleSmartBattery registry entry.
struct BatterySnapshot: Sendable, Equatable {
    var percent: Int
    var isCharging: Bool
    var onAC: Bool
    var isFullyCharged: Bool
    var minutesToFull: Int?
    var minutesToEmpty: Int?

    // From AppleSmartBattery (nil if the registry read fails).
    var cycleCount: Int?
    var designCapacity: Int?
    var nominalCapacity: Int?
    var temperatureC: Double?
    var notChargingReason: Int?

    /// macOS's own Charge Limit, from `pmset -g battlimit`.
    var macOSLimit: MacOSLimit = .unknown
    /// Optimized Battery Charging's own hold level, when powerd has one active.
    var optimizedHold: Int?

    /// Health as NominalChargeCapacity / DesignCapacity, which tracks the
    /// "Maximum Capacity" figure in System Settings more closely than the raw
    /// AppleRawMaxCapacity value.
    var healthPercent: Int? {
        guard let design = designCapacity, design > 0, let nominal = nominalCapacity else { return nil }
        return Int((Double(nominal) / Double(design) * 100).rounded())
    }

    var stateDescription: String {
        if isCharging { return "Charging" }
        if onAC && isFullyCharged { return "Fully charged" }
        if onAC { return "On AC, not charging" }
        return "On battery"
    }

    /// Plain-English reason the charger is idle on AC, or nil when it isn't.
    /// Apple doesn't document `ChargerData.NotChargingReason`; only codes
    /// observed on this hardware are named, everything else shows the raw value.
    var notChargingDescription: String? {
        guard onAC, !isCharging, !isFullyCharged, let reason = notChargingReason, reason != 0 else { return nil }
        switch reason {
        case 0x0100_0000:
            // Same code for both holds; attribute it to whichever one binds at this charge.
            if let hold = optimizedHold, percent >= hold, !macOSLimitBinds { return "Held at \(hold)% by Optimized Battery Charging" }
            return "Held by macOS Charge Limit"
        default: return "Not charging (code \(Self.hex(reason)))"
        }
    }

    private var macOSLimitBinds: Bool {
        if case .on(let limit) = macOSLimit { return percent >= limit }
        return false
    }

    static func hex(_ value: Int) -> String {
        String(format: "0x%08X", value)
    }

    var timeDescription: String? {
        if isCharging, let m = minutesToFull, m > 0 { return "\(Self.format(m)) to full" }
        if !onAC, let m = minutesToEmpty, m > 0 { return "\(Self.format(m)) remaining" }
        return nil
    }

    private static func format(_ minutes: Int) -> String {
        String(format: "%d:%02d", minutes / 60, minutes % 60)
    }
}
