import Foundation
import ObjectiveC

/// Thin runtime bridge to PowerUI's private `PowerUISmartChargeClient`, the
/// client System Settings uses for macOS's own Charge Limit ("MCL").
///
/// Loaded lazily with dlopen/NSClassFromString so the build needs no private
/// headers, and nothing touches PowerUI until the user changes a setting.
@MainActor
final class SmartChargeClient {
    enum Failure: LocalizedError {
        case unavailable(String)
        case rejected(String, NSError?)

        var errorDescription: String? {
            switch self {
            case .unavailable(let what): return "macOS charge limit API unavailable (\(what))"
            case .rejected(let call, let error): return "\(call) failed: \(error?.localizedDescription ?? "no error returned")"
            }
        }
    }

    private typealias ErrorOut = AutoreleasingUnsafeMutablePointer<NSError?>?
    private typealias BoolFn = @convention(c) (AnyObject, Selector) -> ObjCBool
    private typealias BoolErrFn = @convention(c) (AnyObject, Selector, ErrorOut) -> ObjCBool
    private typealias BoolSocErrFn = @convention(c) (AnyObject, Selector, UInt8, ErrorOut) -> ObjCBool

    private let client: AnyObject

    init() throws {
        guard dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI", RTLD_NOW) != nil else {
            throw Failure.unavailable("dlopen PowerUI")
        }
        guard let cls = NSClassFromString("PowerUISmartChargeClient") else {
            throw Failure.unavailable("PowerUISmartChargeClient")
        }
        typealias AllocFn = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>
        typealias InitFn = @convention(c) (AnyObject, Selector, NSString) -> Unmanaged<AnyObject>?

        let allocSel = NSSelectorFromString("alloc")
        let initSel = NSSelectorFromString("initWithClientName:")
        guard let allocMethod = class_getClassMethod(cls, allocSel),
              let initMethod = class_getInstanceMethod(cls, initSel)
        else { throw Failure.unavailable("initWithClientName:") }

        let alloc = unsafeBitCast(method_getImplementation(allocMethod), to: AllocFn.self)
        let initialize = unsafeBitCast(method_getImplementation(initMethod), to: InitFn.self)
        // -init consumes the +1 from +alloc and returns its own +1.
        let raw = alloc(cls, allocSel).takeUnretainedValue()
        guard let instance = initialize(raw, initSel, "chargebar" as NSString)?.takeRetainedValue() else {
            throw Failure.unavailable("initWithClientName: returned nil")
        }
        client = instance
    }

    var isSupported: Bool {
        guard let (sel, fn) = try? method("isMCLSupported", as: BoolFn.self) else { return false }
        return fn(client, sel).boolValue
    }

    /// Sets macOS's Charge Limit target (80–100 on current hardware).
    func setLimit(_ percent: Int) throws {
        try callSoc("setMCLLimit:error:", UInt8(percent.clamped(to: 0...100)))
    }

    func enable() throws { try call("enableMCL:") }
    func disable() throws { try call("disableMCL:") }

    /// "Charge to Full Now": lifts the limit for the current charge only.
    func temporarilyDisable() throws { try call("temporarilyDisableMCL:") }

    /// Charge once to `percent`, then return to the normal limit.
    func overrideTarget(_ percent: Int) throws {
        try callSoc("temporarilyOverrideMCLTargetSoC:error:", UInt8(percent.clamped(to: 0...100)))
    }

    // MARK: - Runtime plumbing

    private func method<T>(_ name: String, as type: T.Type) throws -> (Selector, T) {
        let sel = NSSelectorFromString(name)
        guard let cls = object_getClass(client), let m = class_getInstanceMethod(cls, sel) else {
            throw Failure.unavailable(name)
        }
        return (sel, unsafeBitCast(method_getImplementation(m), to: type))
    }

    private func call(_ name: String) throws {
        let (sel, fn) = try method(name, as: BoolErrFn.self)
        var error: NSError?
        guard fn(client, sel, &error).boolValue else { throw Failure.rejected(name, error) }
    }

    private func callSoc(_ name: String, _ soc: UInt8) throws {
        let (sel, fn) = try method(name, as: BoolSocErrFn.self)
        var error: NSError?
        guard fn(client, sel, soc, &error).boolValue else { throw Failure.rejected(name, error) }
    }
}
