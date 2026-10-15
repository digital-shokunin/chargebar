import Foundation

/// Optional, user-consented route to macOS's Charge Limit: shortcuts the user
/// builds once in Shortcuts.app around the "Set Battery Charge Limit" action
/// (macOS 26.4+), run with `/usr/bin/shortcuts`.
///
/// The action's `limit` parameter only accepts its fixed 80/85/90/95/100
/// choices (no text or number input), so each value is its own shortcut.
enum ChargeLimitShortcuts {
    static let limits = [80, 85, 90, 95, 100]
    static let chargeToFull = "chargebar charge to full"

    static func name(forLimit percent: Int) -> String { "chargebar limit \(percent)" }

    static var allNames: [String] { limits.map(name(forLimit:)) + [chargeToFull] }

    static let setupInstructions = """
        In Shortcuts, create one shortcut per name below. Each contains a single \
        "Set Battery Charge Limit" action.

        \(limits.map { "\u{2022} \(name(forLimit: $0)): Charge Limit \($0)%" }.joined(separator: "\n"))
        \u{2022} \(chargeToFull): Charge Limit 100%, Set Until Tomorrow on

        chargebar uses a shortcut when it exists and falls back to the built-in client otherwise.
        """

    struct Failure: LocalizedError {
        let name: String
        let output: String
        var errorDescription: String? { "Shortcut \"\(name)\" failed: \(output.isEmpty ? "no output" : output)" }
    }

    /// Names of chargebar's shortcuts currently installed.
    nonisolated static func installed() -> Set<String> {
        guard let output = try? shortcuts(["list"]), output.status == 0 else { return [] }
        let present = Set(output.text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
        return Set(allNames).intersection(present)
    }

    nonisolated static func run(_ name: String) throws {
        let output = try shortcuts(["run", name])
        guard output.status == 0 else { throw Failure(name: name, output: output.text) }
    }

    private nonisolated static func shortcuts(_ arguments: [String]) throws -> (status: Int32, text: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
