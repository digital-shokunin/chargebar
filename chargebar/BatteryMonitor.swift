import Foundation
import IOKit
import IOKit.ps

/// Reads battery state and publishes changes. IOPowerSources notifications
/// cover charge/AC transitions; a slow timer picks up temperature and other
/// registry values that change without a power-source event.
@MainActor
final class BatteryMonitor {
    private(set) var snapshot: BatterySnapshot?
    var onChange: ((BatterySnapshot?) -> Void)?

    private var runLoopSource: CFRunLoopSource?
    private var timer: Timer?

    func start() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let monitor = Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue()
            // The source is added to the main run loop, so this fires on the main thread.
            MainActor.assumeIsolated { monitor.refresh() }
        }
        if let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() {
            // Common modes so the menu keeps updating while it is open (event tracking mode).
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = source
        }

        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        refresh()
    }

    func stop() {
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        runLoopSource = nil
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let new = Self.read()
        guard new != snapshot else { return }
        snapshot = new
        onChange?(new)
    }

    // MARK: - Reading

    nonisolated static func read() -> BatterySnapshot? {
        guard var snapshot = readPowerSource() else { return nil }
        let reg = readSmartBattery()
        snapshot.cycleCount = reg["CycleCount"] as? Int
        snapshot.designCapacity = reg["DesignCapacity"] as? Int
        snapshot.nominalCapacity = reg["NominalChargeCapacity"] as? Int
        if let t = reg["Temperature"] as? Int { snapshot.temperatureC = Double(t) / 100 }
        if let charger = reg["ChargerData"] as? [String: Any] {
            snapshot.notChargingReason = charger["NotChargingReason"] as? Int
        }
        if let limits = MacOSLimit.rawOutput() {
            snapshot.macOSLimit = MacOSLimit.parse(limits)
            snapshot.optimizedHold = MacOSLimit.optimizedHold(limits)
        }
        return snapshot
    }

    private nonisolated static func readPowerSource() -> BatterySnapshot? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            else { continue }

            let current = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = desc[kIOPSMaxCapacityKey] as? Int ?? 100
            let percent = max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : current
            return BatterySnapshot(
                percent: percent,
                isCharging: desc[kIOPSIsChargingKey] as? Bool ?? false,
                onAC: desc[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                isFullyCharged: desc[kIOPSIsChargedKey] as? Bool ?? false,
                minutesToFull: desc[kIOPSTimeToFullChargeKey] as? Int,
                minutesToEmpty: desc[kIOPSTimeToEmptyKey] as? Int
            )
        }
        return nil
    }

    private nonisolated static func readSmartBattery() -> [String: Any] {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return [:] }
        defer { IOObjectRelease(service) }

        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any]
        else { return [:] }
        return dict
    }
}
