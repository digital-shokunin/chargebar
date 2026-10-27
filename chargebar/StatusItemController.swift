import AppKit
import os

/// Owns the NSStatusItem and its menu. The menu is rebuilt each time it opens,
/// so it always reflects the latest battery snapshot and settings.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let monitor: BatteryMonitor
    private let settings: Settings
    private let controller: ChargeController
    private let log = Logger(subsystem: "net.digital-shokunin.chargebar", category: "Menu")

    init(monitor: BatteryMonitor, settings: Settings, controller: ChargeController) {
        self.monitor = monitor
        self.settings = settings
        self.controller = controller
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

        monitor.onChange = { [weak self] snapshot in
            guard let self else { return }
            if let snapshot { self.controller.batteryUpdated(snapshot) }
            self.updateButton(snapshot)
        }
        controller.onVerified = { [weak self] ok, actual in self?.flashResult(ok: ok, actual: actual) }
        // Settings are pushed only on explicit user changes, never at launch.
        updateButton(monitor.snapshot)
    }

    // MARK: - Status button

    private var flashUntil: Date?

    /// Shows a limit change's result next to the icon for a few seconds, so it's
    /// visible without reopening the menu.
    private func flashResult(ok: Bool, actual: String) {
        guard let button = statusItem.button else { return }
        button.title = ok ? " limit \(actual) \u{2713}" : " limit not applied \u{2717}"
        button.toolTip = "macOS limit \(actual)"
        let until = Date().addingTimeInterval(4)
        flashUntil = until
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, self.flashUntil == until else { return }
            self.flashUntil = nil
            self.updateButton(self.monitor.snapshot)
        }
    }

    private func updateButton(_ snapshot: BatterySnapshot?) {
        guard let button = statusItem.button else { return }
        if let flashUntil, flashUntil > Date() { return }
        guard let snapshot else {
            button.image = symbol("battery.0percent", description: "Battery unavailable")
            button.title = " --"
            return
        }
        button.image = symbol(Self.symbolName(for: snapshot), description: "Battery \(snapshot.percent)%")
        button.title = " \(snapshot.percent)%"
        button.toolTip = "chargebar \u{2014} \(snapshot.stateDescription), limit \(settings.cap)%"
    }

    static func symbolName(for snapshot: BatterySnapshot) -> String {
        if snapshot.isCharging { return "battery.100percent.bolt" }
        switch snapshot.percent {
        case 88...: return "battery.100percent"
        case 63..<88: return "battery.75percent"
        case 38..<63: return "battery.50percent"
        case 13..<38: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    private func symbol(_ name: String, description: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)
        image?.isTemplate = true
        return image
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        monitor.refresh()
        menu.removeAllItems()

        addDetails(to: menu)
        menu.addItem(.separator())

        menu.addItem(capMenuItem())
        menu.addItem(sailingMenuItem())
        menu.addItem(.separator())

        if controller.isChargingToFull {
            menu.addItem(item("Cancel Charge to Full", #selector(cancelChargeToFull)))
        } else {
            menu.addItem(item("Charge to Full Now", #selector(chargeToFullNow)))
        }
        menu.addItem(chargeOnceMenuItem())
        let installed = ChargeLimitShortcuts.installed().count
        menu.addItem(item("Use Shortcuts (\(installed) of \(ChargeLimitShortcuts.allNames.count) set up)\u{2026}", #selector(showShortcutsSetup)))
        menu.addItem(.separator())

        for title in ["Heat protection", "Manual discharge", "Calibration", "Schedule"] {
            menu.addItem(disabled("\(title) \u{2014} coming later"))
        }
        menu.addItem(.separator())

        let status = controller.status()
        menu.addItem(disabled("Enforcement: \(status.summary)"))
        if let detail = status.detail {
            menu.addItem(disabled(detail))
        }
        menu.addItem(item("Copy Diagnostics", #selector(copyDiagnostics)))
        menu.addItem(.separator())

        let login = item("Launch at Login", #selector(toggleLaunchAtLogin))
        login.state = LaunchAtLogin.isEnabled ? .on : .off
        if LaunchAtLogin.needsApproval {
            login.title = "Launch at Login (approve in System Settings)"
        }
        menu.addItem(login)
        menu.addItem(item("Quit chargebar", #selector(quit), key: "q"))
    }

    private func addDetails(to menu: NSMenu) {
        guard let s = monitor.snapshot else {
            menu.addItem(disabled("No internal battery found"))
            return
        }
        menu.addItem(disabled("Charge: \(s.percent)%  \u{00B7}  Limit: \(settings.cap)%"))
        var state = "State: \(s.stateDescription)"
        if controller.status().chargerCut && !s.onAC {
            state = "State: Plugged in, running on battery (charger paused by chargebar)"
        }
        if let time = s.timeDescription { state += " (\(time))" }
        menu.addItem(disabled(state))
        if let reason = s.notChargingDescription, let code = s.notChargingReason {
            let item = disabled(reason)
            item.toolTip = "NotChargingReason \(BatterySnapshot.hex(code)) (\(code))"
            menu.addItem(item)
        }
        switch s.macOSLimit {
        case .on(let soc): menu.addItem(disabled("macOS limit: \(soc)%"))
        case .off:
            if settings.cap < 100 && !controller.isChargingToFull && s.onAC {
                // On AC, powerd has no active limit although chargebar's cap is below 100:
                // e.g. a Charge to Full lift that never ended. Apple's backstop is off.
                // (While on battery, including a sailing cut, powerd lists no limits at all,
                // so this is only meaningful on AC.)
                menu.addItem(disabled("macOS limit: lifted (no limit active)"))
                menu.addItem(item("Restore macOS Limit", #selector(restoreMacOSLimit)))
            } else if !s.onAC {
                menu.addItem(disabled("macOS limit: inactive on battery"))
            } else {
                menu.addItem(disabled("macOS limit: Off"))
            }
        case .unknown: break
        }
        if let health = s.healthPercent {
            menu.addItem(disabled("Health: \(health)% of design capacity"))
        }
        if let cycles = s.cycleCount {
            menu.addItem(disabled("Cycles: \(cycles)"))
        }
        if let temp = s.temperatureC {
            menu.addItem(disabled(String(format: "Temperature: %.1f \u{00B0}C", temp)))
        }
    }

    private func capMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Charge Limit: \(settings.cap)%", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false

        let guidance = NSMenuItem()
        guidance.view = CapGuidanceView(selectedCap: settings.cap)
        sub.addItem(guidance)
        sub.addItem(.separator())

        for cap in Settings.capChoices {
            let needsHelper = cap < MacOSChargeLimitController.lowestNativeLimit && !HelperClient.isInstalled
            let choice = item(needsHelper ? "\(cap)%  \u{2014} needs helper" : "\(cap)%", #selector(selectCap(_:)))
            choice.representedObject = cap
            choice.state = settings.cap == cap ? .on : .off
            sub.addItem(choice)
        }
        let isCustom = !Settings.capChoices.contains(settings.cap)
        let custom = item(isCustom ? "Custom (\(settings.cap)%)\u{2026}" : "Custom\u{2026}", #selector(promptCustomCap))
        custom.state = isCustom ? .on : .off
        sub.addItem(custom)

        parent.submenu = sub
        return parent
    }

    private func chargeOnceMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Charge Once To", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        for percent in Settings.chargeOnceChoices {
            let choice = item("\(percent)%", #selector(chargeOnce(_:)))
            choice.representedObject = percent
            sub.addItem(choice)
        }
        parent.submenu = sub
        return parent
    }

    private func sailingMenuItem() -> NSMenuItem {
        let title = settings.sailingEnabled
            ? "Sailing Mode: \(settings.cap)% \u{2192} \(settings.sailFloor)%"
            : "Sailing Mode: Off"
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false

        let toggle = item("Enable Sailing", #selector(toggleSailing))
        toggle.state = settings.sailingEnabled ? .on : .off
        sub.addItem(toggle)
        let sleepToggle = item("Keep Sailing During Sleep", #selector(toggleSailDuringSleep))
        sleepToggle.state = settings.sailDuringSleep ? .on : .off
        sleepToggle.toolTip = "Off: the charger is reconnected before sleep and macOS's limit holds. On: it stays off through sleep while charge is more than 5 points above the floor; the helper re-checks on each background wake."
        sub.addItem(sleepToggle)
        sub.addItem(.separator())
        sub.addItem(disabled("Let charge drift down before topping up:"))
        for drift in Settings.sailDriftChoices {
            let floor = max(settings.cap - drift, Settings.customCapRange.lowerBound)
            let choice = item("\(drift) points (resume at \(floor)%)", #selector(selectDrift(_:)))
            choice.representedObject = drift
            choice.state = settings.sailDrift == drift ? .on : .off
            sub.addItem(choice)
        }

        parent.submenu = sub
        return parent
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    #if DEBUG
    /// Dumps the status item and a freshly built menu to stdout (CHARGEBAR_SELFTEST=1).
    func printSelfTest() {
        let button = statusItem.button
        print("statusItem visible=\(statusItem.isVisible) title=\"\(button?.title ?? "nil")\" image=\(button?.image != nil) window=\(button?.window?.frame ?? .zero)")
        guard let menu = statusItem.menu else { return print("no menu") }
        menuNeedsUpdate(menu)
        func dump(_ menu: NSMenu, _ indent: String) {
            for item in menu.items {
                if item.isSeparatorItem { print(indent + "---"); continue }
                if let view = item.view { print(indent + "[view \(type(of: view)) \(view.frame.size)]"); continue }
                let mark = item.state == .on ? "* " : "  "
                print(indent + mark + item.title + (item.isEnabled ? "" : "  (disabled)"))
                if let sub = item.submenu { dump(sub, indent + "    ") }
            }
        }
        dump(menu, "")
    }
    #endif

    // MARK: - Actions

    @objc private func selectCap(_ sender: NSMenuItem) {
        guard let cap = sender.representedObject as? Int else { return }
        settings.cap = cap
        applyCap()
    }

    @objc private func promptCustomCap() {
        let range = Settings.customCapRange
        let alert = NSAlert()
        alert.messageText = "Custom charge limit"
        alert.informativeText = "Enter a whole number from \(range.lowerBound) to \(range.upperBound)."
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        field.integerValue = settings.cap
        let formatter = NumberFormatter()
        formatter.allowsFloats = false
        formatter.minimum = NSNumber(value: range.lowerBound)
        formatter.maximum = NSNumber(value: range.upperBound)
        field.formatter = formatter
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = field.integerValue
        guard range.contains(value) else { return }
        settings.cap = value
        applyCap()
    }

    @objc private func toggleSailing() {
        settings.sailingEnabled.toggle()
        applySailing()
    }

    @objc private func toggleSailDuringSleep() {
        settings.sailDuringSleep.toggle()
        controller.setSailDuringSleep(settings.sailDuringSleep)
    }

    @objc private func selectDrift(_ sender: NSMenuItem) {
        guard let drift = sender.representedObject as? Int else { return }
        settings.sailDrift = drift
        applySailing()
    }

    @objc private func toggleLaunchAtLogin() {
        LaunchAtLogin.setEnabled(!LaunchAtLogin.isEnabled)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    /// Puts status, settings and raw powerd output on the clipboard for bug reports.
    @objc private func copyDiagnostics() {
        let s = monitor.snapshot
        let status = controller.status()
        var lines = [
            "chargebar \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")",
            "Cap: \(settings.cap)%  Sailing: \(settings.sailingEnabled ? "\(settings.cap)->\(settings.sailFloor)%" : "off")",
            "Enforcement: \(status.summary)",
            "Last result: \(status.detail ?? "none")",
        ]
        if let s {
            lines.append("Charge: \(s.percent)%  State: \(s.stateDescription)  macOS limit: \(s.macOSLimit.label)")
            if let code = s.notChargingReason { lines.append("NotChargingReason: \(BatterySnapshot.hex(code))") }
        }
        lines.append("")
        lines.append("$ pmset -g battlimit")
        lines.append(MacOSLimit.rawOutput() ?? "(pmset failed)")
        lines.append("")
        lines.append("$ /usr/bin/log show --last 24h (helper events, last 20)")
        lines.append(Self.recentHelperEvents() ?? "(no helper events)")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    /// The helper's recent cut/reconnect events from the unified log (no root needed).
    /// Note: zsh has a `log` builtin, so the full path matters when run by hand too.
    private static func recentHelperEvents() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["show", "--last", "24h", "--info", "--style", "compact",
                             "--predicate", "subsystem == \"\(HelperClient.serviceName)\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .filter { !$0.hasPrefix("Timestamp") }
            .map { line -> String in
                // "2026-10-27 08:01:02.123 Df net...helper[pid:tid] [subsystem:helper] message" -> "time  message"
                let parts = line.split(separator: " ", maxSplits: 1)
                let time = parts.first.map(String.init) ?? ""
                let message = line.range(of: ":helper] ").map { String(line[$0.upperBound...]) } ?? String(line)
                return "\(time)  \(message)"
            }
        return lines.isEmpty ? nil : lines.suffix(20).joined(separator: "\n")
    }

    @objc private func showShortcutsSetup() {
        let alert = NSAlert()
        alert.messageText = "Control the charge limit with Shortcuts"
        alert.informativeText = ChargeLimitShortcuts.setupInstructions
        alert.addButton(withTitle: "Open Shortcuts")
        alert.addButton(withTitle: "Close")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    @objc private func chargeToFullNow() {
        perform("Charge to Full Now") { try controller.chargeToFullNow() }
    }

    @objc private func cancelChargeToFull() {
        perform("Cancel Charge to Full") { try controller.cancelChargeToFull() }
    }

    @objc private func restoreMacOSLimit() {
        perform("Restore macOS limit") { try controller.restoreMacOSLimit() }
    }

    @objc private func chargeOnce(_ sender: NSMenuItem) {
        guard let percent = sender.representedObject as? Int else { return }
        perform("Charge once to \(percent)%") { try controller.chargeOnce(to: percent) }
    }

    private func applyCap() {
        perform("Set charge limit to \(settings.cap)%") { try controller.setLimit(settings.cap) }
        updateButton(monitor.snapshot)
    }

    private func applySailing() {
        perform("Sailing mode") { try controller.setSailing(floor: settings.sailingEnabled ? settings.sailFloor : nil) }
    }

    /// Runs a controller call; failures are logged and shown, never silently swallowed.
    private func perform(_ action: String, _ body: () throws -> Void) {
        do {
            try body()
        } catch {
            log.error("\(action, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            let alert = NSAlert()
            alert.messageText = "\(action) failed"
            alert.informativeText = error.localizedDescription
            NSApp.activate()
            alert.runModal()
        }
    }
}
