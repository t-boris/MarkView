import Foundation

private var failures = 0

private func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    if condition() {
        print("  ✓ \(label)")
    } else {
        print("  ✗ \(label)")
        failures += 1
    }
}

private func runPhase7WebCITests() {
    print("Phase 7 & Continuous — Web Bridge, mv-kit, CI Consolidation & Documentation Tests")
    let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

    // 1. AR-28 & AR-29: mv-kit.js provides window.mvKit and window.mvBridge
    let mvKitPath = repoRoot.appendingPathComponent("MarkView/Resources/Editor/vendor/js/mv-kit.js")
    let mvKitSrc = (try? String(contentsOf: mvKitPath, encoding: .utf8)) ?? ""
    check(!mvKitSrc.isEmpty, "mv-kit.js exists in MarkView/Resources/Editor/vendor/js/ (AR-28, AR-29)")
    check(
        mvKitSrc.contains("global.mvKit =") && mvKitSrc.contains("global.mvBridge = mvBridge"),
        "mv-kit.js exports window.mvKit and window.mvBridge (AR-28, AR-29)"
    )
    check(
        mvKitSrc.contains("escapeHtml") && mvKitSrc.contains("attachPanZoom") && mvKitSrc.contains("send: function"),
        "mv-kit.js defines shared escapeHtml, attachPanZoom, and mvBridge.send primitives (AR-28, AR-29)"
    )

    // 2. HTML entry points load mv-kit.js and markview-bridge.js delegates to mvBridge
    for htmlName in ["index.html", "discussion.html", "book.html", "terminal.html"] {
        let htmlPath = repoRoot.appendingPathComponent("MarkView/Resources/Editor/\(htmlName)")
        let htmlSrc = (try? String(contentsOf: htmlPath, encoding: .utf8)) ?? ""
        check(
            htmlSrc.contains("vendor/js/mv-kit.js"),
            "\(htmlName) loads vendor/js/mv-kit.js before page scripts (AR-29)"
        )
    }

    let bridgeJSPath = repoRoot.appendingPathComponent("MarkView/Resources/Editor/vendor/js/markview-bridge.js")
    let bridgeJSSrc = (try? String(contentsOf: bridgeJSPath, encoding: .utf8)) ?? ""
    check(
        bridgeJSSrc.contains("window.mvBridge") && bridgeJSSrc.contains("window.mvBridge.send"),
        "markview-bridge.js routes bridge calls through window.mvBridge.send when present (AR-28)"
    )

    // 3. AR-45 & DEC-008: Unified ci.yml workflow with caching and concurrency cancel-in-progress: true
    let ciPath = repoRoot.appendingPathComponent(".github/workflows/ci.yml")
    let ciSrc = (try? String(contentsOf: ciPath, encoding: .utf8)) ?? ""
    check(!ciSrc.isEmpty, ".github/workflows/ci.yml exists (AR-45, DEC-008)")
    check(
        ciSrc.contains("concurrency:") && ciSrc.contains("cancel-in-progress: true"),
        "ci.yml configures concurrency group with cancel-in-progress: true (AR-45, DEC-008)"
    )
    check(
        ciSrc.contains("actions/cache/restore@v4") && ciSrc.contains("swift test --package-path Packages/MarkViewCore"),
        "ci.yml runs MarkViewCore swift test and caches DerivedData (AR-44, AR-45)"
    )

    for wf in ["build-release.yml", "publish-release.yml", "copilot-cockpit.yml", "remote-workspace.yml"] {
        let wfPath = repoRoot.appendingPathComponent(".github/workflows/\(wf)")
        let wfSrc = (try? String(contentsOf: wfPath, encoding: .utf8)) ?? ""
        check(
            wfSrc.contains("concurrency:"),
            "\(wf) declares a concurrency group (AR-45)"
        )
    }

    // Superseded per-feature workflows removed
    for removedWf in ["bug-validity.yml", "document-files.yml", "editor-diagrams.yml", "pdf-book.yml", "themes.yml"] {
        let removedPath = repoRoot.appendingPathComponent(".github/workflows/\(removedWf)")
        check(
            !FileManager.default.fileExists(atPath: removedPath.path),
            "Superseded workflow \(removedWf) removed in favor of unified ci.yml (AR-45, DEC-008)"
        )
    }

    // 4. AR-49: CLAUDE.md, tasks/todo.md rotation, and architecture-review-2026-11.md alignment
    let claudeSrc = (try? String(contentsOf: repoRoot.appendingPathComponent("CLAUDE.md"), encoding: .utf8)) ?? ""
    check(
        claudeSrc.contains("Packages/MarkViewCore") && !claudeSrc.contains("cd EditorWeb"),
        "CLAUDE.md references Packages/MarkViewCore and removes obsolete EditorWeb instructions (AR-49, DEC-004, DEC-006)"
    )
    check(
        claudeSrc.contains("tools/tests/run.sh") && claudeSrc.contains("mv-kit.js"),
        "CLAUDE.md documents tools/tests/run.sh and mv-kit.js (AR-49)"
    )

    let todoSrc = (try? String(contentsOf: repoRoot.appendingPathComponent("tasks/todo.md"), encoding: .utf8)) ?? ""
    let archiveExists = FileManager.default.fileExists(
        atPath: repoRoot.appendingPathComponent("tasks/archive/todo-archive-2026-11.md").path
    )
    check(
        archiveExists && todoSrc.components(separatedBy: "\n").count < 500,
        "tasks/todo.md rotated into tasks/archive/todo-archive-2026-11.md (AR-49)"
    )

    let archReviewSrc = (try? String(
        contentsOf: repoRoot.appendingPathComponent("docs/architecture/architecture-review-2026-11.md"),
        encoding: .utf8
    )) ?? ""
    check(
        archReviewSrc.contains("Phase 7: web modernisation (4-6 weeks, incremental) — [Done].") &&
        archReviewSrc.contains("Continuous — [Done]."),
        "docs/architecture/architecture-review-2026-11.md records all phases and Continuous items as [Done] (AR-49)"
    )
}

runPhase7WebCITests()
if failures > 0 {
    print("FAILED: \(failures) check(s)")
    exit(1)
}
print("All Phase 7 & Continuous web, CI & documentation checks passed.")
