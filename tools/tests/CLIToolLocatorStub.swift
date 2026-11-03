import Foundation
// Compile-time stand-in for CLIToolLocator (see github-remote-profile-tests.sh and
// new-project-tests.sh): the checks never start a CLI, they only need the type to exist.
enum CLIToolLocator {
    static func subprocessPath(toolPath: String?) -> String {
        ProcessInfo.processInfo.environment["MARKVIEW_GITHUB_TEST_PATH"] ?? "/usr/bin:/bin"
    }
}
