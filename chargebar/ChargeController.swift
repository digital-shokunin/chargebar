import Foundation
import os

struct ChargeControllerStatus: Sendable {
    var summary: String
    /// Extra detail for the menu (e.g. last verification result), if any.
    var detail: String?
}

/// The enforcement layer: whatever actually stops the charger at the cap.
///
/// `MacOSChargeLimitController` drives macOS's own Charge Limit (80–100).
/// Caps below 80 and sailing need the CHIE-based helper, which doesn't exist
/// yet (see NOTES.md); until then they are recorded and logged only.
@MainActor
protocol ChargeController: AnyObject {
    var name: String { get }
    func setLimit(_ percent: Int) throws
    /// Enable sailing between `floor` and the current limit, or pass nil to disable.
    func setSailing(floor: Int?) throws
    /// Travel mode: lift every limit for the current charge.
    func chargeToFullNow() throws
    /// Charge once to `percent`, then return to the normal limit.
    func chargeOnce(to percent: Int) throws
    func status() -> ChargeControllerStatus
    /// Called after a limit change has been checked against powerd.
    var onVerified: ((_ ok: Bool, _ message: String) -> Void)? { get set }
}

/// No-op controller: logs what it would do. Safe to run anywhere.
@MainActor
final class LoggingChargeController: ChargeController {
    let name = "Logging (no hardware writes)"
    var onVerified: ((_ ok: Bool, _ message: String) -> Void)?

    private let log = Logger(subsystem: "net.digital-shokunin.chargebar", category: "ChargeController")

    func setLimit(_ percent: Int) throws {
        log.info("setLimit(\(percent, privacy: .public)) requested; not enforced")
    }

    func setSailing(floor: Int?) throws {
        log.info("setSailing(floor: \(floor.map(String.init) ?? "off", privacy: .public)) requested; not enforced")
    }

    func chargeToFullNow() throws {
        log.info("chargeToFullNow requested; not enforced")
    }

    func chargeOnce(to percent: Int) throws {
        log.info("chargeOnce(to: \(percent, privacy: .public)) requested; not enforced")
    }

    func status() -> ChargeControllerStatus {
        ChargeControllerStatus(summary: "Not enforced (logging only)")
    }
}
