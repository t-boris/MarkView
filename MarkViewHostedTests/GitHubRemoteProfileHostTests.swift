import Foundation
import Darwin
import MarkViewCore
import XCTest
@testable import MarkView

/// Checks that a Git remote is recognized as GitHub through an SSH host alias, and that a
/// folder's `gh` configuration directory is resolved from its `.ghprofile`.
private enum GitHubRemoteProfileChecks {
    static func run() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("mv-github-remote-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try remotesWithoutAliases(home: home)
        try aliasedRemotes(home: home)
        let suite = "github-profile-host-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try profiles(home: home, settings: Settings(defaults))
    }

    // MARK: Remotes

    static func remotesWithoutAliases(home: URL) throws {
        let expected: [String: String?] = [
            "git@github.com:owner/name.git": "owner/name",
            "https://github.com/owner/name.git": "owner/name",
            "https://github.com/owner/name": "owner/name",
            "ssh://git@github.com/owner/name.git": "owner/name",
            "git@gitlab.com:owner/name.git": nil,
            "https://example.com/owner/name.git": nil
        ]
        for (url, slug) in expected {
            let actual = GitHubClient.slug(fromRemoteURL: url, home: home)
            XCTAssertTrue(actual == slug, "\(url) resolved to \(actual ?? "nil"), expected \(slug ?? "nil")")
        }
    }

    static func aliasedRemotes(home: URL) throws {
        let config = """
            # A personal identity reached through an alias.
            Host github-personal
              HostName github.com
              User git

            Host gl-*
              HostName gitlab.com

            Include config.d/*.conf
            """
        try config.write(to: home.appendingPathComponent(".ssh/config"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh/config.d"), withIntermediateDirectories: true)
        try "Host gh-work\n  HostName github.com\n"
            .write(to: home.appendingPathComponent(".ssh/config.d/work.conf"), atomically: true, encoding: .utf8)

        XCTAssertTrue(SSHHostAliases.resolve("github-personal", home: home) == "github.com")
        XCTAssertTrue(SSHHostAliases.resolve("gh-work", home: home) == "github.com", "An Include'd file must be read.")
        XCTAssertTrue(SSHHostAliases.resolve("gl-main", home: home) == "gitlab.com", "A wildcard Host pattern must match.")
        XCTAssertTrue(SSHHostAliases.resolve("unknown-host", home: home) == "unknown-host")
        DispatchQueue.concurrentPerform(iterations: 200) { _ in
            XCTAssertTrue(SSHHostAliases.resolve("gh-work", home: home) == "github.com", "Concurrent cache reads must agree.")
        }

        XCTAssertTrue(GitHubClient.slug(fromRemoteURL: "git@github-personal:owner/name.git", home: home) == "owner/name")
        XCTAssertTrue(GitHubClient.slug(fromRemoteURL: "ssh://git@gh-work/owner/name.git", home: home) == "owner/name")
        XCTAssertTrue(GitHubClient.slug(fromRemoteURL: "git@gl-main:owner/name.git", home: home) == nil,
                     "An alias that is not GitHub must stay unrecognized.")

        // An edited configuration is picked up rather than served from the cache.
        try (config + "\nHost later\n  HostName github.com\n")
            .write(to: home.appendingPathComponent(".ssh/config"), atomically: true, encoding: .utf8)
        XCTAssertTrue(SSHHostAliases.resolve("later", home: home) == "github.com", "A changed ~/.ssh/config must be re-read.")
    }

    // MARK: Profiles

    static func profiles(home: URL, settings: Settings) throws {
        let project = home.appendingPathComponent("Projects/app")
        let nested = project.appendingPathComponent("docs/features")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        XCTAssertTrue(GitHubProfile.resolve(root: project, home: home, settings: settings).directory == nil,
                     "Without a marker file gh keeps its own configuration.")

        try "personal\n".write(to: project.appendingPathComponent(".ghprofile"), atomically: true, encoding: .utf8)
        XCTAssertTrue(GitHubProfile.resolve(root: project, home: home, settings: settings).directory == nil,
                     "A marker naming a profile that does not exist must not invent a directory.")

        let profile = home.appendingPathComponent(".config/gh-profiles/personal")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let resolved = GitHubProfile.resolve(root: project, home: home, settings: settings)
        XCTAssertTrue(resolved.directory?.path == profile.path, "The profile directory must come from .ghprofile.")
        XCTAssertTrue(resolved.name == "personal")
        XCTAssertTrue(GitHubProfile.resolve(root: nested, home: home, settings: settings).directory?.path == profile.path,
                     "A subfolder follows the marker of the folder above it.")

        try "GHP_SSH_KEY=\"~/.ssh/id_personal\"\nGHP_TOKEN='secret-token' # inline\n"
            .write(to: profile.appendingPathComponent("profile.env"), atomically: true, encoding: .utf8)
        let withEnvironment = GitHubProfile.resolve(root: project, home: home, settings: settings)
        XCTAssertTrue(withEnvironment.token == "secret-token", "Quotes and trailing comments must be stripped.")
        XCTAssertTrue(withEnvironment.sshCommand == "ssh -i \(home.path)/.ssh/id_personal -o IdentitiesOnly=yes")

        var environment = ["GITHUB_TOKEN": "inherited", "PATH": "/usr/bin"]
        GitHubProfile.apply(to: &environment, root: project, home: home, settings: settings)
        XCTAssertTrue(environment["GH_CONFIG_DIR"] == profile.path)
        XCTAssertTrue(environment["GITHUB_TOKEN"] == "secret-token")
        XCTAssertTrue(environment["PATH"] == "/usr/bin")

        // A profile without a token must drop an inherited one: it belongs to another account.
        try "".write(to: profile.appendingPathComponent("profile.env"), atomically: true, encoding: .utf8)
        var inherited = ["GITHUB_TOKEN": "inherited"]
        GitHubProfile.apply(to: &inherited, root: project, home: home, settings: settings)
        XCTAssertTrue(inherited["GITHUB_TOKEN"] == nil, "An inherited token would override the profile's own credentials.")

        // An explicit setting wins over the folder's marker.
        let chosen = home.appendingPathComponent("chosen-config")
        settings.set(chosen.path, for: Setting.gitHubConfigDirectory)
        XCTAssertTrue(GitHubProfile.resolve(root: project, home: home, settings: settings).directory?.path == chosen.path)
        settings.remove(Setting.gitHubConfigDirectory)
    }
}

extension EditorHostTests {
    func testGitHubRemoteProfiles() throws { try GitHubRemoteProfileChecks.run() }
}
