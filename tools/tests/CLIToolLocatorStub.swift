import Foundation
// Compile-time stand-in for CLIToolLocator used by the new-project and Git task ownership checks.
enum CLIToolLocator {
    static func subprocessPath(toolPath: String?) -> String {
        ProcessInfo.processInfo.environment["MARKVIEW_GITHUB_TEST_PATH"] ?? "/usr/bin:/bin"
    }
}
