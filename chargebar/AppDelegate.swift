import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let monitor = BatteryMonitor()
    private let settings = Settings()
    private lazy var controller: ChargeController = MacOSChargeLimitController(
        initialCap: settings.cap,
        initialSailingFloor: settings.sailingEnabled ? settings.sailFloor : nil,
        sailDuringSleep: settings.sailDuringSleep
    )
    private var statusController: StatusItemController?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusController = StatusItemController(monitor: monitor, settings: settings, controller: controller)
        monitor.start()
        #if DEBUG
        if ProcessInfo.processInfo.environment["CHARGEBAR_SELFTEST"] != nil {
            statusController?.printSelfTest()
            NSApp.terminate(nil)
        }
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
    }
}
