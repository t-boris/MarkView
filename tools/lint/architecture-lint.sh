#!/bin/bash
# Architecture lint (FU-28, CLAUDE.md "Architecture & Refactoring Rules" 4): the structural rules of the repository, kept out of
# the feature tests. It reads the working tree, lists every violation and exits 1 when there is one. CI runs it in the pure job.
#
# Rules that must hold:
#   no-loose-swift       no *.swift directly in MarkView/Models or MarkView/Views (every file lives in a domain folder)
#   no-vendor-markview   no reference to `vendor/js/markview-` in the app's Swift code and HTML (the scripts live in Editor/js)
#   target-membership    every MarkView/**/*.swift on disk is a file reference and a Sources build file of the Xcode target in
#                        MarkView.xcodeproj/project.pbxproj, and every Swift file the project references exists on disk
#   semantic-database-actor  MarkView/Models/Insight/SemanticDatabase.swift declares `actor SemanticDatabase` and no @MainActor, so
#                        none of its sqlite3 calls can run on the main thread (AR-37)
#   bridge-no-bypass     (AR-28) the editor page's scripts send through mvBridge.send only: no `messageHandlers` in
#                        Editor/js/*.js (except mv-kit.js, the one sender, and markview-ui-studio-*.js, a different host) or in
#                        EditorWindowPrefs.swift, and no string `case "..."` in Bridge/WebViewBridge.swift (handlers are registered)
#   no-private-escape    (AR-29) no private HTML escaping in Editor/js/*.js: every `&amp;` literal outside mv-kit.js (mvKit.escapeHtml and
#                        escapeAttr are the one implementation) needs an `mvkit-exempt:` note within three lines above it
#   js-interpolation     (AR-04) no `evaluateJavaScript(` or `callAsyncJavaScript(` in MarkView/ or Packages/ takes a script that is built by
#                        string interpolation `\(...)`, directly or through a variable or a helper function: a script that takes values
#                        is a `JS.call(function, args:)` (JSON-encoded arguments) or a constant literal with `arguments:`. A raw string
#                        (`#"..."#`) interpolates with `\#(`; it is not scanned and is for a script made of compile-time constants only
#   webview-configuration (AR-27) no `WKWebViewConfiguration(...)` and no `WKWebView(...)` in MarkView/: every host makes its configuration
#                        with WebHost.makeConfiguration and its web view with WebHost.makeWebView (a subclass of WKWebView calls
#                        WebHost.markInspectable), so handlers are registered weakly and a Debug build is inspectable the same way
#   settings-literal     (AR-18) no setting is named by a string literal outside the registry: no `@AppStorage("...")`, `@WindowStorage("...")`
#                        or `AppStorage(wrappedValue: x, "...")`, and no direct UserDefaults call (`UserDefaults.standard.set`,
#                        `defaults.string(forKey:)` ...) in MarkView/ or in a package's Sources outside Settings.swift: a setting is a
#                        SettingsKey of `Setting` (Packages/MarkViewCore SettingsKeys.swift), read and written through `Settings`
#   settings-observer    (AR-18) no `didChangeNotification` outside Settings.swift: the notification fires on every write to the
#                        preferences (a divider drag, a window's own state); a view or a model that follows a setting uses
#                        SettingsObserver(keys) or SettingsObserver.changes(of:), which calls back only when one of its keys changed
#   tabs-direct          (AR-15) a view never reads the window's tabs (openTabs, activeTab, activeTabIndex, lastSaveError) through the
#                        manager, and the manager never forwards a part's objectWillChange (tabs, file tree, layout, Git) into its own:
#                        a view observes the part it shows, so typing redraws what shows the tabs and nothing else
#   (the ratchets below also include window-wiring, AR-17: closure hooks assigned after construction, references to the window's
#                        whole WorkspaceManager, and hooks a view writes into a model)
#   unchecked-sendable   (AR-43) every `@unchecked Sendable` and `nonisolated(unsafe)` in MarkView/ and Packages/ says what guards it, in a
#                        `// unchecked Sendable: <what guards it>` comment on the same or the previous line; a type that can be
#                        checked says `Sendable` and a value behind a lock is an OSAllocatedUnfairLock, so the escape hatch stays rare
# Ratchets: a count that may fall and never rise. Today's sites are listed per file in an allow-list; a new site or a higher
# count fails, and so does a lower count that the list does not yet say (run `--tighten`), so that the allowance never has slack.
#   process              Process() outside Packages/MarkViewCore Subprocess.swift     tools/lint/process-allowlist.txt
#   clicompletion        CLICompletion.run outside Models/AI/AIOperation.swift          tools/lint/clicompletion-allowlist.txt
#   workspace-manager    `@EnvironmentObject ... WorkspaceManager` declarations         tools/lint/workspace-manager-views.txt
#   assistant-switch     a literal `.claude` / `.codex` / `.cline` / `.copilot` / `.antigravity` outside Models/AI/Providers
#                        (a `case`, a comparison, a default: the assistants are named only by their providers)  tools/lint/assistant-switch-allowlist.txt
#   atomic-write         `.write(to:` / `.write(toFile:` outside AtomicFile (CoreFiles.swift)  tools/lint/atomic-write-allowlist.txt
#   project-paths        a string literal that starts with `.dde` or `.markview-` outside ProjectPaths (CoreFiles.swift)
#                        tools/lint/project-paths-allowlist.txt
#   app-log              `NSLog(` and `Logger(subsystem:` outside AppLog (Packages/MarkViewCore AppLog.swift)  tools/lint/app-log-allowlist.txt
#   domain-cycles        (AR-21) a back-edge between two domain folders of Models (or of Views) that depend on each other: the count is the
#                        number of types the back-edge names (tools/lint/domain-dependencies.py measures it; `--why A B` lists them).
#                        `<count> Models/<from> -> Models/<to>  # why it stays` in tools/lint/domain-cycles-allowlist.txt; a pair that
#                        becomes a cycle is a new entry the lint refuses until a person writes it down with its reason
#   window-wiring        (AR-17) three lists: closure `var` hooks of Models classes and protocols (window-wiring-hooks.txt), Models that hold
#                        the whole WorkspaceManager or a back-reference set after construction (window-wiring-backrefs.txt), and hooks that a
#                        view writes into the window's models (window-wiring-views.txt)
# A migration that reaches zero ends with an empty list (no lines), which means none allowed.
#
# Usage: tools/lint/architecture-lint.sh [--root <repo>] [--tighten]
#   --root     lint another tree (the self-test uses a fixture); default: this repository
#   --tighten  rewrite the allow-lists to today's counts; refuses when any count rose or a new site exists
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TIGHTEN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --root) ROOT="$(cd "${2:?--root requires a folder}" && pwd)"; shift 2 ;;
        --tighten) TIGHTEN=1; shift ;;
        *) echo "usage: $0 [--root <repo>] [--tighten]" >&2; exit 2 ;;
    esac
done

exec python3 - "$ROOT" "$TIGHTEN" "$(cd "$(dirname "$0")" && pwd)" <<'PY'
import importlib.util
import json
import re
import subprocess
import sys
from pathlib import Path

sys.dont_write_bytecode = True   # importing domain-dependencies.py must not leave a __pycache__ in the repository
root, tighten, lint_dir = Path(sys.argv[1]), sys.argv[2] == "1", Path(sys.argv[3])
violations = []   # (rule, message)
notes = []

def swift_files(*folders):
    found = []
    for folder in folders:
        base = root / folder
        if base.is_dir():
            found += sorted(p for p in base.rglob("*.swift") if p.is_file())
    return found

def rel(path):
    return path.relative_to(root).as_posix()

def code_lines(path):
    """The lines of a Swift file that are not whole-line comments, with their numbers."""
    for number, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
        if not line.lstrip().startswith("//"):
            yield number, line

# --- no-loose-swift
for folder in ("MarkView/Models", "MarkView/Views"):
    base = root / folder
    if base.is_dir():
        for path in sorted(base.glob("*.swift")):
            violations.append(("no-loose-swift", f"{rel(path)}: a Swift file directly in {folder}; move it into a domain folder"))

# --- no-vendor-markview
pattern = "vendor/js/markview-"
app = root / "MarkView"
if app.is_dir():
    for path in sorted(p for p in app.rglob("*") if p.is_file() and p.suffix in (".swift", ".html")):
        for number, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
            if pattern in line:
                violations.append(("no-vendor-markview", f"{rel(path)}:{number}: references `{pattern}`; the editor scripts live in Resources/Editor/js"))

# --- target-membership
def project_swift_files():
    """(files referenced by the project, files in the Sources build phases of its native targets), as repo-relative paths."""
    project = root / "MarkView.xcodeproj" / "project.pbxproj"
    converted = subprocess.run(["plutil", "-convert", "json", "-o", "-", str(project)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if converted.returncode != 0:
        raise RuntimeError(f"plutil could not read {rel(project)}: {converted.stderr.strip()}")
    objects = json.loads(converted.stdout)["objects"]
    parent = {}
    for key, obj in objects.items():
        if obj["isa"] == "PBXGroup":
            for child in obj.get("children", []):
                parent[child] = key
    def full_path(key):
        parts = []
        while key:
            obj = objects[key]
            where, name = obj.get("sourceTree"), obj.get("path")
            if where == "<group>" and name:
                parts.append(name)
            elif where in ("SOURCE_ROOT", "<absolute>") and name:
                parts.append(name)
                break
            key = parent.get(key)
        return "/".join(reversed(parts))
    refs = {key: full_path(key) for key, obj in objects.items()
            if obj["isa"] == "PBXFileReference" and obj.get("path", "").endswith(".swift")}
    built = set()
    for obj in objects.values():
        if obj["isa"] != "PBXNativeTarget":
            continue
        for phase_key in obj.get("buildPhases", []):
            phase = objects[phase_key]
            if phase["isa"] != "PBXSourcesBuildPhase":
                continue
            for build_key in phase.get("files", []):
                ref = objects[build_key].get("fileRef")
                if ref in refs:
                    built.add(refs[ref])
    return set(refs.values()), built

if (root / "MarkView.xcodeproj" / "project.pbxproj").is_file():
    try:
        referenced, built = project_swift_files()
        on_disk = {rel(p) for p in swift_files("MarkView")}
        for path in sorted(on_disk - referenced):
            violations.append(("target-membership", f"{path}: on disk but not a file reference of MarkView.xcodeproj"))
        for path in sorted((on_disk & referenced) - built):
            violations.append(("target-membership", f"{path}: referenced by MarkView.xcodeproj but not in the target's Sources build phase"))
        for path in sorted(referenced - on_disk):
            violations.append(("target-membership", f"{path}: referenced by MarkView.xcodeproj but missing on disk"))
        for path in sorted(built - referenced):
            violations.append(("target-membership", f"{path}: in the Sources build phase but not on disk"))
    except (RuntimeError, OSError, KeyError, ValueError) as error:
        violations.append(("target-membership", f"could not compare the project with the disk: {error}"))
else:
    violations.append(("target-membership", "MarkView.xcodeproj/project.pbxproj is missing"))

# --- ratchets
def count_sites(files, matcher, exclude=lambda path: False):
    counts = {}
    for path in files:
        if exclude(path):
            continue
        hits = sum(1 for _, line in code_lines(path) if matcher.search(line))
        if hits:
            counts[rel(path)] = hits
    return counts

allowlist_cache = {}     # list name -> {path: allowed count}, or None when the list does not exist
allowlist_reasons = {}   # (list name, path) -> the `# reason` after an entry, kept when the list is rewritten

def read_allowlist(name):
    """The allowance per file, or None when the list does not exist. An entry may end in `  # why it stays`."""
    if name in allowlist_cache:
        return allowlist_cache[name]
    path = root / "tools" / "lint" / name
    if not path.is_file():
        allowlist_cache[name] = None
        return None
    allowed = {}
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        text = line.strip()
        if not text or text.startswith("#"):
            continue
        match = re.fullmatch(r"(\d+)\s+(\S.*?)(?:\s+#\s*(\S.*))?", text)
        if not match or match.group(2) in allowed:
            violations.append((name, f"tools/lint/{name}:{number}: expected `<count> <path>` once per path"))
            continue
        allowed[match.group(2)] = int(match.group(1))
        if match.group(3):
            allowlist_reasons[(name, match.group(2))] = match.group(3)
    allowlist_cache[name] = allowed
    return allowed

def write_allowlist(name, header, counts):
    lines = [header.rstrip("\n")] + [
        f"{count} {path}" + (f"  # {allowlist_reasons[(name, path)]}" if (name, path) in allowlist_reasons else "")
        for path, count in sorted(counts.items())]
    (root / "tools" / "lint" / name).write_text("\n".join(lines) + "\n", encoding="utf-8")

def ratchet(rule, name, noun, counts, header, label=None, unit="file(s)"):
    allowed = read_allowlist(name)
    if allowed is None:
        if tighten:
            write_allowlist(name, header, counts)
            notes.append(f"{label or rule}: created tools/lint/{name} with {sum(counts.values())} in {len(counts)} {unit}")
        else:
            violations.append((rule, f"tools/lint/{name} is missing (create it with --tighten)"))
        return
    rose = {path: (allowed.get(path, 0), count) for path, count in counts.items() if count > allowed.get(path, 0)}
    fell = {path: (allowed[path], counts.get(path, 0)) for path in allowed if counts.get(path, 0) < allowed[path]}
    if tighten:
        if rose:
            for path, (was, now) in sorted(rose.items()):
                violations.append((rule, f"{path}: {now} {noun}, {was} allowed; --tighten only lowers the allowance"))
        else:
            write_allowlist(name, header, counts)
            return
    else:
        for path, (was, now) in sorted(rose.items()):
            kind = "new" if was == 0 else "more"
            violations.append((rule, f"{path}: {now} {noun}, {was} allowed ({kind} sites); remove them instead of adding"))
        for path, (was, now) in sorted(fell.items()):
            violations.append((rule, f"{path}: {now} {noun}, {was} allowed; the count fell, lower the allowance in tools/lint/{name} (--tighten) so it cannot rise again"))
    total = sum(counts.values())
    notes.append(f"{label or rule}: {total} in {len(counts)} {unit}, {sum(allowed.values())} allowed")

app_swift = swift_files("MarkView")
package_swift = swift_files("Packages")
ratchet("process", "process-allowlist.txt", "Process() site(s)",
        count_sites(app_swift + package_swift, re.compile(r"(?<![A-Za-z0-9_])Process\(\)"),
                    exclude=lambda p: rel(p).startswith("Packages/MarkViewCore/") and p.name == "Subprocess.swift"),
        "# Process() sites outside Packages/MarkViewCore Subprocess.swift (AR-25). `<count> <path>`; a ratchet that only falls.\n"
        "# Run tools/lint/architecture-lint.sh --tighten after removing a site; the goal is an empty list.")
ratchet("clicompletion", "clicompletion-allowlist.txt", "CLICompletion.run call(s)",
        count_sites(app_swift, re.compile(r"CLICompletion\.run"), exclude=lambda p: rel(p) == "MarkView/Models/AI/AIOperation.swift"),
        "# CLICompletion.run calls outside Models/AI/AIOperation.swift (AR-26). `<count> <path>`; a ratchet that only falls.\n"
        "# Run tools/lint/architecture-lint.sh --tighten after removing a call; the goal is an empty list.")
ratchet("workspace-manager", "workspace-manager-views.txt", "@EnvironmentObject WorkspaceManager declaration(s)",
        count_sites(app_swift, re.compile(r"@EnvironmentObject\b.*:\s*WorkspaceManager\b")),
        "# `@EnvironmentObject ... WorkspaceManager` declarations: views that take the whole manager (AR-14). `<count> <path>`; a ratchet\n"
        "# that only falls. Run tools/lint/architecture-lint.sh --tighten after narrowing a view's dependency.")

MAX_SWIFT_LINES = 2000

def oversize_lines(files):
    """Lines beyond MAX_SWIFT_LINES per Swift file; a file that fits does not appear."""
    counts = {}
    for path in files:
        total = len(path.read_text(encoding="utf-8", errors="replace").splitlines())
        if total > MAX_SWIFT_LINES:
            counts[rel(path)] = total - MAX_SWIFT_LINES
    return counts

ratchet("file-size", "file-size-allowlist.txt", f"line(s) beyond {MAX_SWIFT_LINES}", oversize_lines(app_swift + package_swift),
        f"# Swift files longer than {MAX_SWIFT_LINES} lines (AR-16): `<lines beyond the limit> <path>`; a ratchet that only falls. Split a file along\n"
        "# its responsibilities (a type with its own state, not an extension that only moves lines) and run --tighten; the goal is an empty list.")

ASSISTANT_LITERAL = re.compile(r"(?<![\w\"/~.\-])\.(?:claude|codex|cline|copilot|antigravity)\b")

def assistant_sites(files):
    """Lines that name an assistant by an enum literal; a trailing `// ...` comment does not count."""
    counts = {}
    for path in files:
        if rel(path).startswith("MarkView/Models/AI/Providers/"):
            continue
        hits = sum(1 for _, line in code_lines(path) if ASSISTANT_LITERAL.search(re.split(r"\s//", line)[0]))
        if hits:
            counts[rel(path)] = hits
    return counts

ratchet("assistant-switch", "assistant-switch-allowlist.txt", "assistant literal(s)", assistant_sites(app_swift),
        "# Lines outside Models/AI/Providers that name an assistant (`.claude`, `.codex`, ...): a switch case, a comparison or a\n"
        "# default (AR-35). `<count> <path>`; a ratchet that only falls. Run tools/lint/architecture-lint.sh --tighten after removing\n"
        "# a site; the goal is an empty list: an assistant is described by its provider and nowhere else.")

ratchet("atomic-write", "atomic-write-allowlist.txt", "direct file write(s)",
        count_sites(app_swift + package_swift, re.compile(r"\.write\((?:to|toFile):"),
                    exclude=lambda p: "/Tests/" in rel(p) or "/.build/" in rel(p) or rel(p) == "Packages/MarkViewCore/Sources/MarkViewCore/CoreFiles.swift"),
        "# `.write(to:` / `.write(toFile:` outside AtomicFile (AR-24). `<count> <path>`; a ratchet that only falls. What may stay: a user's own\n"
        "# export or download (PDF, picture, HTML export), a scratch file in the temporary folder or a staging folder that is published by one\n"
        "# move, a file that must never replace an existing one (`.withoutOverwriting`), and an append-only log. Everything else, every file\n"
        "# of app or project state, goes through AtomicFile.write. Run tools/lint/architecture-lint.sh --tighten after converting a site.")

ratchet("project-paths", "project-paths-allowlist.txt", "path literal(s)",
        count_sites(app_swift + package_swift, re.compile(r'"\.(?:dde|markview-)'),
                    exclude=lambda p: "/Tests/" in rel(p) or "/.build/" in rel(p) or rel(p) == "Packages/MarkViewCore/Sources/MarkViewCore/CoreFiles.swift"),
        "# String literals that start with `.dde` or `.markview-` outside ProjectPaths (AR-24). `<count> <path>`; a ratchet that only falls.\n"
        "# The folders and files MarkView keeps in a project are named once, by ProjectPaths in Packages/MarkViewCore (CoreFiles.swift), with a\n"
        "# test per path. Add a location there instead of writing the literal. Prose that merely mentions `.dde/` in a longer sentence is not a\n"
        "# path and is not counted.")

ratchet("app-log", "app-log-allowlist.txt", "NSLog or Logger site(s)",
        count_sites(app_swift + package_swift, re.compile(r"(?<![A-Za-z0-9_.])NSLog\(|(?<![A-Za-z0-9_])Logger\(subsystem:"),
                    exclude=lambda p: "/Tests/" in rel(p) or "/.build/" in rel(p) or rel(p) == "Packages/MarkViewCore/Sources/MarkViewCore/AppLog.swift"),
        "# `NSLog(` and `Logger(subsystem:` outside AppLog (AR-24). `<count> <path>`; a ratchet that only falls. Every message goes through a\n"
        "# category of AppLog (Packages/MarkViewCore, AppLog.swift), which keeps interpolated strings private. Add a category there instead of a\n"
        "# new Logger, and never log file contents, tokens, prompts or request headers.")

# --- domain-cycles (AR-21)
def domain_back_edges():
    """{`<layer>/<from> -> <layer>/<to>`: types} for the back-edge of every pair of domain folders that depend on each other.
    The direction an allow-list entry names stays the back-edge; a new pair gets the heuristic of domain-dependencies.py."""
    spec = importlib.util.spec_from_file_location("domain_dependencies", lint_dir / "domain-dependencies.py")
    measuring = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(measuring)
    named = read_allowlist("domain-cycles-allowlist.txt") or {}
    preferred = {}
    for key in named:
        found = re.fullmatch(r"(Models|Views)/(\w+) -> (Models|Views)/(\w+)", key)
        if found and found.group(1) == found.group(3):
            preferred.setdefault(found.group(1), set()).add((found.group(2), found.group(4)))
    counts = {}
    for layer, measured in measuring.measure(root).items():
        for pair in measured["pairs"]:
            source, target, weight, _ = measuring.back_edge(pair, preferred.get(layer, set()))
            counts[f"{layer}/{source} -> {layer}/{target}"] = weight
    return counts

ratchet("domain-cycles", "domain-cycles-allowlist.txt", "type(s) named back across a cycle", domain_back_edges(),
        "# Back-edges between domain folders that depend on each other (AR-21): `<types> <layer>/<from> -> <layer>/<to>  # why it stays`. The\n"
        "# types are the ones <from> names that <to> declares (tools/lint/domain-dependencies.py --layer <layer> --why <from> <to> lists them).\n"
        "# A ratchet that only falls: remove the dependency (a protocol in the lower domain, or move the type) and run --tighten; the goal is an\n"
        "# empty list. The back-edge points away from `Workspace`, which composes the others; a pair that is not listed gets the lighter\n"
        "# direction. A new cycle is written here by a person, with the reason it stays.",
        unit="pair(s)")

# --- window-wiring (AR-17)
# A window's object graph is built in one place (WindowComposition). A feature gets what it needs of the window through a narrow
# protocol or an initializer parameter, never through a closure that another object assigns after construction, never by holding the
# window's whole `WorkspaceManager`, and never by a view that writes a hook into a model.
WIRING_TYPE = [(re.compile(r"\b(?:class|actor)\s+[A-Za-z_]"), "class"), (re.compile(r"\bprotocol\s+[A-Za-z_]"), "protocol"),
               (re.compile(r"\b(?:struct|enum)\s+[A-Za-z_]"), "value"), (re.compile(r"\bextension\s+[A-Za-z_]"), "extension")]
WIRING_DECL = re.compile(r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*((?:(?:private|fileprivate|internal|public|open|static|weak|unowned|lazy|nonisolated(?:\(unsafe\))?|final|override|private\(set\)|fileprivate\(set\)|internal\(set\)|public\(set\))\s+)*)(var|let)\s+([A-Za-z_]\w*)\s*:\s*(.*)$")
BACKREF_SET = re.compile(r"(?<![A-Za-z0-9_])\w+\??\.(?:workspace|manager|workspaceManager|host|presenter)\s*=\s*self\b")
VIEW_HOOK = re.compile(r"\b(?:workspaceManager|workspace|manager|wm)\.[A-Za-z_][\w.]*\s*=\s*(?:\{|\[(?:weak|unowned)|self\b)")

def wiring_scrub(line):
    return re.sub(r'"(?:\\.|[^"\\])*"', '""', line).split("//")[0]

def wiring_kind(prefix):
    if re.search(r"\bfunc\b|\binit\b|\bdeinit\b|\bsubscript\b|=\s*$|\bget\b|\bset\b|\bdidSet\b|\bwillSet\b", prefix):
        return "other"
    for matcher, kind in WIRING_TYPE:
        if matcher.search(prefix):
            return kind
    return "other"

def wiring_sites(files):
    """(hooks, backrefs) per file. A hook is a stored `var` of function type that other code assigns after the object exists: declared
    in a class, an actor or a protocol (`{ get set }`), not private, not static (a `let` is an initializer parameter and is fine).
    A back-reference is a stored property or requirement that mentions `WorkspaceManager`, or an assignment `x.host = self` (or
    `.workspace`, `.manager`, `.workspaceManager`, `.presenter`) made after construction."""
    hooks, backrefs = {}, {}
    for path in files:
        stack = []
        carry = ""   # the start of a declaration that continues on this line (`class A: B,` then `C {`)
        for _, raw in code_lines(path):
            line = wiring_scrub(raw)
            if not line.strip():
                continue
            head, carry = carry, (carry + " " + line.strip()) if line.rstrip().endswith((",", "&", ":", "(")) else ""
            top = stack[-1] if stack else None
            match = WIRING_DECL.match(line)
            if match and top in ("class", "protocol", "value"):
                modifiers, keyword, _, rest = match.groups()
                if "WorkspaceManager" in rest:
                    backrefs[rel(path)] = backrefs.get(rel(path), 0) + 1
                elif top != "value" and keyword == "var" and not re.search(r"\b(?:static|private|fileprivate)\b", modifiers):
                    declared = re.split(r"\s=\s|\s=$", rest)[0].strip()
                    declared = re.sub(r"\{\s*get\s+set\s*\}\s*$", "", declared).strip()
                    declared = re.sub(r"^(?:@\w+(?:\([^)]*\))?\s+)+", "", declared)
                    if "->" in declared and declared.startswith("(") and "{" not in declared and "}" not in declared:
                        hooks[rel(path)] = hooks.get(rel(path), 0) + 1
            if BACKREF_SET.search(line):
                backrefs[rel(path)] = backrefs.get(rel(path), 0) + 1
            for index, char in enumerate(line):
                if char == "{":
                    stack.append(wiring_kind(head + " " + line[:index]))
                elif char == "}" and stack:
                    stack.pop()
    return hooks, backrefs

model_files = [path for path in app_swift if rel(path).startswith("MarkView/Models/")]
wiring_hooks, wiring_backrefs = wiring_sites(model_files)
ratchet("window-wiring", "window-wiring-hooks.txt", "closure wiring propert(ies) (a `var` of function type in a class or protocol; inject a protocol or an initializer parameter)",
        wiring_hooks,
        "# Closure-typed `var` properties of classes, actors and protocols in MarkView/Models that other code assigns after construction (AR-17).\n"
        "# `<count> <path>`; a ratchet that only falls. A feature takes a narrow protocol or an initializer parameter from WindowComposition\n"
        "# (an event is a publisher); run tools/lint/architecture-lint.sh --tighten after removing a site.", label="window-wiring (hooks)")
ratchet("window-wiring", "window-wiring-backrefs.txt", "reference(s) to the window's WorkspaceManager (a property of its type, or `x.host = self` after construction)",
        wiring_backrefs,
        "# Models that hold the window's whole WorkspaceManager, and back-references set after construction (`x.host = self`) (AR-17).\n"
        "# `<count> <path>`; a ratchet that only falls. A feature holds a narrow host protocol that WindowComposition passes at init;\n"
        "# run tools/lint/architecture-lint.sh --tighten after removing a site.", label="window-wiring (back-references)")
view_hooks = {}
for path in swift_files("MarkView/Views"):
    hits = sum(1 for _, line in code_lines(path) if VIEW_HOOK.search(re.split(r"\s//", line)[0]))
    if hits:
        view_hooks[rel(path)] = hits
ratchet("window-wiring", "window-wiring-views.txt", "hook(s) a view writes into the window's models (`manager.part.x = { ... }` or `= self`)",
        view_hooks,
        "# Views that assign a closure or `self` to a part of the window's manager (AR-17). `<count> <path>`; a ratchet that only falls.\n"
        "# The model publishes what happened and the view subscribes, or the model is given its collaborator at construction.",
        label="window-wiring (views)")

# --- semantic-database-actor
database = root / "MarkView" / "Models" / "Insight" / "SemanticDatabase.swift"
if database.is_file():
    if not any(re.match(r"\s*actor\s+SemanticDatabase\b", line) for _, line in code_lines(database)):
        violations.append(("semantic-database-actor", f"{rel(database)}: `SemanticDatabase` must be declared as an `actor`; its SQLite calls must not run on the main thread"))
    for number, line in code_lines(database):
        if "@MainActor" in line:
            violations.append(("semantic-database-actor", f"{rel(database)}:{number}: `@MainActor` in the database; its SQLite calls must stay off the main thread"))

# --- bridge-no-bypass
bridge_senders = {"mv-kit.js"}   # and the UI Studio runtime parts below: a different host with its own handler
page_files = []
js_dir = root / "MarkView" / "Resources" / "Editor" / "js"
if js_dir.is_dir():
    page_files += sorted(p for p in js_dir.glob("*.js") if p.is_file() and p.name not in bridge_senders and not p.name.startswith("markview-ui-studio-"))
page_files += [p for p in [root / "MarkView" / "Models" / "Workspace" / "EditorWindowPrefs.swift"] if p.is_file()]
for path in page_files:
    for number, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
        if "messageHandlers" in line and not line.lstrip().startswith(("//", "*", "/*")):
            violations.append(("bridge-no-bypass", f"{rel(path)}:{number}: talks to `messageHandlers` directly; send through mvBridge.send so the contract is checked"))
for relative in ("MarkView/Bridge/WebViewBridge.swift",):
    path = root / relative
    if path.is_file():
        for number, line in code_lines(path):
            if re.match(r'\s*case\s+"', line):
                violations.append(("bridge-no-bypass", f"{relative}:{number}: a string `case` on a message type; register a typed handler (TypedWebBridge.on) instead"))

# --- no-private-escape
if js_dir.is_dir():
    for path in sorted(p for p in js_dir.glob("*.js") if p.is_file() and p.name != "mv-kit.js"):
        text_lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        for index, line in enumerate(text_lines):
            if "&amp;" in line and not any("mvkit-exempt:" in near for near in text_lines[max(0, index - 3):index + 1]):
                violations.append(("no-private-escape", f"{rel(path)}:{index + 1}: escapes HTML itself; use window.mvKit.escapeHtml / escapeAttr"))

# --- js-interpolation (AR-04)
def skip_literal(text, i):
    """`text[i]` starts a Swift string literal (`"`, `\"\"\"`, or raw `#"`). Returns (index after it, whether it interpolates with `\\(`)."""
    hashes = 0
    k = i
    while text[k] == "#":
        hashes += 1
        k += 1
    multi = text.startswith('"' * 3, k)
    k += 3 if multi else 1
    close = ('"' * 3 if multi else '"') + "#" * hashes
    marker = "\\" + "#" * hashes
    interpolates = False
    while k < len(text):
        if text.startswith(close, k):
            return k + len(close), interpolates
        if text.startswith(marker, k):
            k += len(marker)
            if k < len(text) and text[k] == "(":
                if hashes == 0:
                    interpolates = True
                k = skip_group(text, k)
            else:
                k += 1
            continue
        k += 1
    return k, interpolates

def skip_group(text, i):
    """`text[i]` is `(`: the index after its matching `)`, with string literals skipped whole."""
    depth = 0
    k = i
    while k < len(text):
        c = text[k]
        if c == '"' or (c == "#" and re.match(r'#+"', text[k:k + 40])):
            k, _ = skip_literal(text, k)
            continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return k + 1
        k += 1
    return k

def expression(text, i, stop_at_comma):
    """The Swift expression that starts at `text[i]`: (its text, whether a string literal in it interpolates). It ends at a
    top-level `)` or `,` (an argument) or, for an initializer, at the first line break that does not continue it."""
    k = i
    depth = 0
    interpolates = False
    while k < len(text):
        c = text[k]
        if c == '"' or (c == "#" and re.match(r'#+"', text[k:k + 40])):
            k, hit = skip_literal(text, k)
            interpolates = interpolates or hit
            continue
        if c in "([{":
            depth += 1
        elif c in ")]}":
            if depth == 0:
                break
            depth -= 1
        elif c == "," and depth == 0 and stop_at_comma:
            break
        elif c == "\n" and depth == 0 and not stop_at_comma:
            rest = text[k:].lstrip()
            if not rest.startswith(("+", ".", "?", ":", "&&", "||")):
                break
        k += 1
    return text[i:k], interpolates

def function_bodies(files):
    """name -> [(file, line, body text)] of every `func name(` in the given files."""
    found = {}
    for path in files:
        text = path.read_text(encoding="utf-8", errors="replace")
        for match in re.finditer(r"\bfunc\s+([A-Za-z_]\w*)\s*[<(]", text):
            brace = text.find("{", match.end())
            if brace < 0:
                continue
            depth, k = 0, brace
            while k < len(text):
                c = text[k]
                if c == '"' or (c == "#" and re.match(r'#+"', text[k:k + 40])):
                    k, _ = skip_literal(text, k)
                    continue
                if c == "{":
                    depth += 1
                elif c == "}":
                    depth -= 1
                    if depth == 0:
                        break
                k += 1
            found.setdefault(match.group(1), []).append((path, text.count("\n", 0, match.start()) + 1, text[brace:k]))
    return found

def literal_interpolates(text):
    """Whether any string literal in `text` interpolates with `\\(`."""
    k = 0
    while k < len(text):
        c = text[k]
        if c == '"' or (c == "#" and re.match(r'#+"', text[k:k + 40])):
            k, hit = skip_literal(text, k)
            if hit:
                return True
            continue
        k += 1
    return False

script_files = swift_files("MarkView", "Packages")
script_functions = function_bodies(script_files)
for path in script_files:
    if "/Tests/" in rel(path):
        continue
    text = path.read_text(encoding="utf-8", errors="replace")
    for match in re.finditer(r"\b(?:evaluateJavaScript|callAsyncJavaScript)\(", text):
        line_start = text.rfind("\n", 0, match.start()) + 1
        if text[line_start:match.start()].lstrip().startswith("//"):
            continue
        number = text.count("\n", 0, match.start()) + 1
        argument, interpolates = expression(text, match.end(), True)
        argument = argument.strip()
        where = f"{rel(path)}:{number}"
        if argument.startswith("JS."):
            continue
        if interpolates:
            violations.append(("js-interpolation", f"{where}: the script is built by string interpolation; use JS.call(function, args:) or a constant script with `arguments:`"))
            continue
        name = re.match(r"^(?:[A-Za-z_]\w*\.)*([A-Za-z_]\w*)\s*(\(|$)", argument)
        if not name:
            continue
        if name.group(2) == "(":   # a helper function builds the script
            for helper_path, helper_line, body in script_functions.get(name.group(1), []):
                if literal_interpolates(body):
                    violations.append(("js-interpolation", f"{where}: `{name.group(1)}` ({rel(helper_path)}:{helper_line}) builds the script by string interpolation"))
            continue
        # a variable or a property: its initializer (a bare name is looked up in this file, a qualified one in all files)
        declaration = None
        text_of = text
        pattern = r"\b(?:static\s+)?(?:let|var)\s+" + re.escape(name.group(1)) + r"\b[^=\n{]*=\s*"
        for candidate in re.finditer(pattern, text):
            if declaration is None or candidate.start() < match.start():
                declaration = candidate
        if declaration is None and "." in argument.split("(")[0]:
            for other in script_files:
                other_text = other.read_text(encoding="utf-8", errors="replace")
                found = re.search(pattern, other_text)
                if found:
                    declaration, text_of = found, other_text
                    break
        if declaration is None:
            continue   # a parameter: the caller builds the script
        initializer, init_interpolates = expression(text_of, declaration.end(), False)
        if initializer.strip().startswith("JS."):
            continue
        if init_interpolates:
            violations.append(("js-interpolation", f"{where}: `{name.group(1)}` is built by string interpolation; use JS.call(function, args:)"))
            continue
        helper = re.match(r"\s*(?:[A-Za-z_]\w*\.)*([A-Za-z_]\w*)\s*\(", initializer)
        if helper:
            for helper_path, helper_line, body in script_functions.get(helper.group(1), []):
                if literal_interpolates(body):
                    violations.append(("js-interpolation", f"{where}: `{name.group(1)}` comes from `{helper.group(1)}` ({rel(helper_path)}:{helper_line}), which builds the script by string interpolation"))

# --- webview-configuration (AR-27)
creation = re.compile(r"(?<![A-Za-z0-9_])(WKWebViewConfiguration|WKWebView)\s*\(")
for path in swift_files("MarkView"):
    for number, line in code_lines(path):
        found = creation.search(re.split(r"\s//", line)[0])
        if found:
            violations.append(("webview-configuration", f"{rel(path)}:{number}: creates a `{found.group(1)}` itself; use WebHost.makeConfiguration and WebHost.makeWebView"))

# --- settings-literal and settings-observer (AR-18)
settings_home = "Packages/MarkViewCore/Sources/MarkViewCore/Settings.swift"
settings_files = [p for p in app_swift + [q for q in package_swift if "/Sources/" in rel(q)] if rel(p) != settings_home]
storage_literal = re.compile(r'(?<![A-Za-z0-9_])(?:AppStorage|WindowStorage)\s*\(\s*(?:wrappedValue\s*:[^,"]*,\s*)?"')
defaults_call = re.compile(r"(?<![A-Za-z0-9_])(?:UserDefaults\.standard|UserDefaults\s*\(|(?:defaults|ud|userDefaults)\s*\.\s*(?:set|string|bool|integer|double|float|object|data|array|stringArray|dictionary|url|removeObject|register|setVolatileDomain|removePersistentDomain)\()")
for path in settings_files:
    for number, line in code_lines(path):
        text = re.split(r"\s//", line)[0]
        if storage_literal.search(text):
            violations.append(("settings-literal", f"{rel(path)}:{number}: names a setting by a string literal; pass a SettingsKey from `Setting` (SettingsKeys.swift)"))
        elif defaults_call.search(text):
            violations.append(("settings-literal", f"{rel(path)}:{number}: reads or writes UserDefaults directly; use `Settings` with a key from `Setting`"))
        if "didChangeNotification" in text:
            violations.append(("settings-observer", f"{rel(path)}:{number}: observes every UserDefaults write; use SettingsObserver(keys) or SettingsObserver.changes(of:)"))

# --- unchecked-sendable (AR-43)
unchecked_escape = re.compile(r"@unchecked\s+Sendable|nonisolated\s*\(\s*unsafe\s*\)")
unchecked_reason = re.compile(r"//\s*unchecked Sendable:\s*\S")
for path in app_swift + package_swift:
    source = path.read_text(encoding="utf-8", errors="replace").splitlines()
    for number, line in code_lines(path):
        if not unchecked_escape.search(re.split(r"\s//", re.sub(r'"(?:[^"\\]|\\.)*"', '""', line))[0]):
            continue
        before = source[number - 2].strip() if number >= 2 else ""
        if unchecked_reason.search(line) or (before.startswith("//") and unchecked_reason.search(before)):
            continue
        violations.append(("unchecked-sendable", f"{rel(path)}:{number}: `@unchecked Sendable` or `nonisolated(unsafe)` without a `// unchecked Sendable: <what guards it>` comment on the same or the previous line"))

# --- tabs-direct
tab_read = re.compile(r"\b(?:workspaceManager|manager|workspace|wm)\??\.(?:openTabs|activeTab|activeTabIndex|lastSaveError)\b")
for path in swift_files("MarkView/Views"):
    for number, line in code_lines(path):
        if tab_read.search(line):
            violations.append(("tabs-direct", f"{rel(path)}:{number}: reads the window's tabs through the manager; take TabsController as an @EnvironmentObject so the view redraws with them"))
forwarded = re.compile(r"\b(?:tabs|chrome|requests|project\.fileTree|layout|gitClient)\.objectWillChange\b")
manager_file = root / "MarkView" / "Models" / "Workspace" / "WorkspaceManager.swift"
if manager_file.is_file():
    for number, line in code_lines(manager_file):
        if forwarded.search(line):
            violations.append(("tabs-direct", f"{rel(manager_file)}:{number}: forwards a part's changes into the manager's objectWillChange; the views that show the part observe it"))

# --- report
rules = ["no-loose-swift", "no-vendor-markview", "target-membership", "semantic-database-actor", "process", "clicompletion", "workspace-manager", "file-size", "assistant-switch", "atomic-write", "project-paths", "app-log", "domain-cycles", "bridge-no-bypass", "no-private-escape", "tabs-direct", "js-interpolation", "webview-configuration", "settings-literal", "settings-observer", "window-wiring", "unchecked-sendable"]
if violations:
    print(f"architecture-lint: {len(violations)} violation(s)")
    for rule in rules + sorted({r for r, _ in violations} - set(rules)):
        for found_rule, message in violations:
            if found_rule == rule:
                print(f"  [{rule}] {message}")
    for note in notes:
        print(f"  ({note})")
    sys.exit(1)
print("architecture-lint: " + ", ".join(rules) + " hold")
for note in notes:
    print(f"  {note}")
PY
