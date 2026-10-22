import Foundation
import XPC
import os

/// What chargebar-helper reports back after each message.
struct HelperStatus: Sendable, Equatable {
    var state: String      // "cutting", "charging", "idle", ...
    var chie: Int
    var percent: Int
    var enabled: Bool
    var cap: Int
    var floor: Int
    var error: String?

    var isCutting: Bool { state == "cutting" }
}

/// XPC client for the root helper (`helper/chargebar-helper.c`), which switches
/// the charger with SMC key CHIE to enforce caps below 80% and sailing.
///
/// The helper reconnects the charger if it hasn't heard from us for 5 minutes,
/// so the policy is re-sent every 60 s as a heartbeat.
@MainActor
final class HelperClient {
    static let serviceName = "net.digital-shokunin.chargebar.helper"

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/\(serviceName).plist")
    }

    private(set) var lastStatus: HelperStatus?
    private(set) var lastError: String?
    var onUpdate: (() -> Void)?

    private let log = Logger(subsystem: "net.digital-shokunin.chargebar", category: "Helper")
    private var connection: xpc_connection_t?

    func sendPolicy(enabled: Bool, cap: Int, floor: Int) {
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(message, "op", "policy")
        xpc_dictionary_set_bool(message, "enabled", enabled)
        xpc_dictionary_set_int64(message, "cap", Int64(cap))
        xpc_dictionary_set_int64(message, "floor", Int64(floor))
        send(message)
    }

    private func send(_ message: xpc_object_t) {
        let connection = connect()
        xpc_connection_send_message_with_reply(connection, message, .main) { [weak self] reply in
            let status = Self.parse(reply)  // convert to a Sendable value before hopping
            MainActor.assumeIsolated { self?.handle(status) }
        }
    }

    private func connect() -> xpc_connection_t {
        if let connection { return connection }
        let new = xpc_connection_create_mach_service(Self.serviceName, .main, UInt64(XPC_CONNECTION_MACH_SERVICE_PRIVILEGED))
        xpc_connection_set_event_handler(new) { [weak self] event in
            guard xpc_get_type(event) == XPC_TYPE_ERROR else { return }
            // Interrupted or invalidated (helper restarted, not installed, or refused us):
            // drop the connection and reconnect on the next send.
            MainActor.assumeIsolated { self?.dropConnection() }
        }
        xpc_connection_resume(new)
        connection = new
        return new
    }

    private func dropConnection() {
        if let connection { xpc_connection_cancel(connection) }
        connection = nil
    }

    /// nil when the reply is an XPC error (helper missing, restarted, or refused us).
    private nonisolated static func parse(_ reply: xpc_object_t) -> HelperStatus? {
        guard xpc_get_type(reply) == XPC_TYPE_DICTIONARY else { return nil }
        return HelperStatus(
            state: string(reply, "state") ?? "?",
            chie: Int(xpc_dictionary_get_int64(reply, "chie")),
            percent: Int(xpc_dictionary_get_int64(reply, "percent")),
            enabled: xpc_dictionary_get_bool(reply, "enabled"),
            cap: Int(xpc_dictionary_get_int64(reply, "cap")),
            floor: Int(xpc_dictionary_get_int64(reply, "floor")),
            error: string(reply, "error")
        )
    }

    private func handle(_ status: HelperStatus?) {
        guard let status else {
            lastError = Self.isInstalled ? "not responding" : "not installed"
            lastStatus = nil
            dropConnection()
            onUpdate?()
            return
        }
        if status != lastStatus {
            log.info("helper: \(status.state, privacy: .public) CHIE=\(status.chie) at \(status.percent)%")
        }
        lastStatus = status
        lastError = status.error
        onUpdate?()
    }

    private nonisolated static func string(_ dict: xpc_object_t, _ key: String) -> String? {
        xpc_dictionary_get_string(dict, key).map { String(cString: $0) }
    }
}
