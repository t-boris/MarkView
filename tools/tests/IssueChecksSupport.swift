import Foundation

// Shared by standalone QA and workflow checks: one pass/fail counter.
var failures = 0

func check(_ name: String, _ condition: Bool) {
    if condition { print("ok  \(name)") } else { failures += 1; print("FAIL \(name)") }
}

func finish(_ suite: String) -> Never {
    print(failures == 0 ? "All \(suite) checks passed" : "\(failures) \(suite) check(s) failed")
    exit(failures == 0 ? 0 : 1)
}
