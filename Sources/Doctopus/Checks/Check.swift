import Foundation

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
