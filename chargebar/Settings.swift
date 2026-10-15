import Foundation

/// User preferences, persisted in UserDefaults.
@MainActor
final class Settings {
    static let capChoices = [60, 65, 70, 75, 80, 85, 90, 95, 100]
    static let chargeOnceChoices = [85, 90, 95, 100]
    static let customCapRange = 20...100
    static let sailDriftChoices = [5, 10, 15, 20]

    private enum Key {
        static let cap = "chargeLimit"
        static let sailingEnabled = "sailingEnabled"
        static let sailDrift = "sailDrift"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // RESEARCH.md: cap at 75, sail down to 65 before topping up.
        defaults.register(defaults: [
            Key.cap: 75,
            Key.sailingEnabled: false,
            Key.sailDrift: 10,
        ])
    }

    var cap: Int {
        get { defaults.integer(forKey: Key.cap) }
        set { defaults.set(newValue.clamped(to: Self.customCapRange), forKey: Key.cap) }
    }

    var sailingEnabled: Bool {
        get { defaults.bool(forKey: Key.sailingEnabled) }
        set { defaults.set(newValue, forKey: Key.sailingEnabled) }
    }

    /// How far (in percentage points) the charge may drift below the cap
    /// before charging resumes.
    var sailDrift: Int {
        get { defaults.integer(forKey: Key.sailDrift) }
        set { defaults.set(newValue.clamped(to: 1...50), forKey: Key.sailDrift) }
    }

    /// Lower bound of the sailing window.
    var sailFloor: Int { max(cap - sailDrift, Self.customCapRange.lowerBound) }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
