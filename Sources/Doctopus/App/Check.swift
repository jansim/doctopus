import Foundation

/// Assertion bookkeeping for the headless checks. Every check prints its own
/// line so a passing run still reads as a report, and any failure makes the
/// process exit non-zero, which is all CI looks at.
enum Check {
    nonisolated(unsafe) private static var passed = 0
    nonisolated(unsafe) private static var failures: [String] = []

    static func that(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        let suffix = detail().isEmpty ? "" : "  (\(detail()))"
        if ok {
            passed += 1
            print("  ✓ \(name)\(suffix)")
        } else {
            failures.append(name)
            print("  ✗ \(name)\(suffix)")
        }
    }

    static func finish(_ label: String) -> Never {
        print("\n\(failures.isEmpty ? "✓" : "✗") \(label): \(passed) passed, \(failures.count) failed")
        for failure in failures { print("    failed: \(failure)") }
        exit(failures.isEmpty ? 0 : 1)
    }
}
