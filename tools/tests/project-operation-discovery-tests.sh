#!/bin/zsh
set -eu

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_root="$(mktemp -d /tmp/markview-operations-test.XXXXXX)"
trap 'rm -rf "$test_root"' EXIT

mkdir -p "$test_root/project" "$test_root/infra/scripts"
print '../infra contains the install procedure.' > "$test_root/project/README.md"
# BUG-114: a second document names a folder inside the first one, so the same script is reachable through both granted folders.
mkdir -p "$test_root/project/docs"
print 'The scripts live in ../../infra/scripts as well.' > "$test_root/project/docs/runbook.md"
print '{"scripts":{"build":"echo build"}}' > "$test_root/project/package.json"
mkdir -p "$test_root/project/server"
print '[project]' > "$test_root/project/server/pyproject.toml"
print 'plugins {}' > "$test_root/project/server/build.gradle.kts"
print 'echo install' > "$test_root/infra/scripts/install.sh"
print 'SECRET=do-not-read' > "$test_root/infra/.env"
ln -s "$test_root/infra/.env" "$test_root/infra/scripts/linked.env"

cat > "$test_root/main.swift" <<'SWIFT'
import Foundation

struct ArchitectureScanner {
    static func isDeploymentHint(_ path: String) -> Bool { path == "Makefile" }
}

@main struct Check {
    static func main() {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let first = ProjectOperationDiscovery.scan(root: root)
        precondition(first.files.contains { $0.location == "package.json" })
        precondition(first.files.contains { $0.location == "server/pyproject.toml" })
        precondition(first.files.contains { $0.location == "server/build.gradle.kts" })
        // The second document grants the nested folder as well; a file reachable through both must still be listed once, because
        // discover() keys the source fingerprints by file path and a repeated path used to abort the app (BUG-114).
        precondition(first.grantedFolders.count == 2)
        precondition(Set(first.files.map(\.url.path)).count == first.files.count)
        precondition(first.files.filter { $0.location.hasSuffix("install.sh") }.count == 1)
        precondition(first.files.contains { $0.location.hasSuffix("install.sh") && $0.external })
        precondition(!first.files.contains { $0.location.hasSuffix(".env") || $0.location.hasSuffix("linked.env") })
        try! "{\"scripts\":{\"build\":\"echo changed\"}}".write(
            to: root.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        let second = ProjectOperationDiscovery.scan(root: root)
        precondition(first.signature != second.signature)
        print("Project operation source scan: passed")
    }
}
SWIFT

swiftc -parse-as-library "$repo_root/MarkView/Models/ProjectOperationDiscovery.swift" "$test_root/main.swift" -o "$test_root/check"
"$test_root/check" "$test_root/project"
