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
            if ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" {
                let message = (name + suffix).replacingOccurrences(of: "%", with: "%25")
                    .replacingOccurrences(of: "\r", with: "%0D")
                    .replacingOccurrences(of: "\n", with: "%0A")
                print("::error::\(message)")
            }
        }
    }

    static func finish(_ label: String) -> Never {
        print("\n\(failures.isEmpty ? "✓" : "✗") \(label): \(passed) passed, \(failures.count) failed")
        for failure in failures { print("    failed: \(failure)") }
        exit(failures.isEmpty ? 0 : 1)
    }
}
