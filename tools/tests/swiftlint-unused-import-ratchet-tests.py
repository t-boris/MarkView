#!/usr/bin/env python3
"""Exercise analyzer failure handling without requiring SourceKit or changing the baseline."""
import os
import importlib.util
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
CHECK = ROOT / "tools/lint/swiftlint-unused-import-ratchet.py"
SOURCE = "Packages/MarkViewCore/Sources/MarkViewCore/AnyCodable.swift"
sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location("unused_import_changes", ROOT / "tools/ci/unused-import-changes.py")
CHANGES = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHANGES)


class RatchetTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        fake = pathlib.Path(self.folder.name) / "swiftlint"
        fake.write_text("""#!/usr/bin/env python3
import json, os, sys, time
mode = os.environ['FAKE_ANALYZER']
if mode == 'timeout': time.sleep(3)
count = {'ok': 1, 'extra': 2, 'slack': 0, 'wrong': 1}.get(mode, 0)
rule = 'force_try' if mode == 'wrong' else 'unused_import'
print(json.dumps([{'file': sys.argv[-1], 'rule_id': rule}] * count))
print('Done analyzing! Found 0 violations in ' + ('0' if mode == 'zero' else '1') + ' files.', file=sys.stderr)
""")
        fake.chmod(0o755)
        self.env = dict(os.environ, PATH=self.folder.name + os.pathsep + os.environ["PATH"])
        self.log = pathlib.Path(self.folder.name) / "compiler.log"
        self.log.write_text("fixture")
        self.baseline = pathlib.Path(self.folder.name) / "baseline.txt"
        self.baseline.write_text(f"1 {SOURCE}\n")

    def run_check(self, mode):
        return subprocess.run([str(CHECK), "--compiler-log", str(self.log), "--baseline", str(self.baseline),
                               "--files", SOURCE, "--timeout", "1"],
                              cwd=ROOT, env=dict(self.env, FAKE_ANALYZER=mode), capture_output=True, text=True)

    def test_exact_baseline_passes(self):
        result = self.run_check("ok")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("1 analyzed files", result.stdout)

    def test_zero_files_is_failure(self):
        self.assertNotEqual(self.run_check("zero").returncode, 0)

    def test_unexpected_rule_is_failure(self):
        self.assertNotEqual(self.run_check("wrong").returncode, 0)

    def test_new_diagnostic_is_failure(self):
        self.assertNotEqual(self.run_check("extra").returncode, 0)

    def test_slack_requires_tightening(self):
        self.assertNotEqual(self.run_check("slack").returncode, 0)

    def test_timeout_is_failure(self):
        self.assertNotEqual(self.run_check("timeout").returncode, 0)

    def test_duplicate_or_invalid_baseline_fails(self):
        for content in (f"1 {SOURCE}\n1 {SOURCE}\n", f"0 {SOURCE}\n", "not-a-count file.swift\n"):
            with self.subTest(content=content):
                self.baseline.write_text(content)
                self.assertNotEqual(self.run_check("ok").returncode, 0)


class CompilerSelectionTests(unittest.TestCase):
    def test_compiler_entries_include_existing_app_and_package_sources_only(self):
        with tempfile.TemporaryDirectory(prefix="compiler log with spaces ") as folder:
            root = pathlib.Path(folder)
            app = root / "MarkView/Views/File With Space.swift"
            core = root / "Packages/MarkViewCore/Sources/MarkViewCore/Model.swift"
            test = root / "MarkViewHostedTests/Fixture.swift"
            for path in (app, core, test):
                path.parent.mkdir(parents=True, exist_ok=True)
                path.touch()
            log = "\n".join([
                f"SwiftCompile normal arm64 {app} (in target 'MarkView' from project 'MarkView')",
                f"SwiftCompile normal arm64 {core} (in target 'MarkViewCore' from project 'MarkViewCore')",
                f"SwiftCompile normal arm64 {test} (in target 'MarkViewHostedTests' from project 'MarkView')",
                "SwiftCompile normal arm64 Compiling\\ One.swift,\\ Two.swift (in target 'MarkView' from project 'MarkView')",
                f"SwiftCompile normal arm64 {root}/MarkView/Missing.swift (in target 'MarkView' from project 'MarkView')",
                f"SwiftCompile normal arm64 {app} (in target 'MarkView' from project 'MarkView')",
            ])
            self.assertEqual(CHANGES.compiled_sources(log, root), {
                "MarkView/Views/File With Space.swift", "Packages/MarkViewCore/Sources/MarkViewCore/Model.swift"
            })

    def test_bounded_selection_never_hides_the_changed_files(self):
        selected, limited = CHANGES.select_sources(["changed.swift"], {"changed.swift", "dependent.swift"}, maximum=2)
        self.assertEqual(selected, ["changed.swift", "dependent.swift"])
        self.assertFalse(limited)
        selected, limited = CHANGES.select_sources(["changed.swift"], {"dependent.swift", "other.swift"}, maximum=2)
        self.assertEqual(selected, ["changed.swift"])
        self.assertTrue(limited)
        selected, limited = CHANGES.select_sources(["a.swift", "b.swift", "c.swift"], {"dependent.swift"}, maximum=2)
        self.assertEqual(selected, ["a.swift", "b.swift", "c.swift"])
        self.assertTrue(limited)

    def test_recompiled_unchanged_file_diagnostic_fails_the_real_wrapper(self):
        with tempfile.TemporaryDirectory(prefix="unused-import-integration-") as folder:
            root = pathlib.Path(folder)
            for relative in ("tools/ci/unused-import-changes.py", "tools/lint/swiftlint-unused-import-ratchet.py"):
                destination = root / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(ROOT / relative, destination)
            (root / "tools/lint/swiftlint-unused-import-allowlist.txt").write_text("")
            app = root / "MarkView"
            app.mkdir()
            changed = app / "Changed.swift"
            dependent = app / "Dependent.swift"
            changed.write_text("let before = 1\n")
            dependent.write_text("let dependent = 2\n")
            git_env = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
            subprocess.run(["git", "init", "-q", str(root)], check=True, env=git_env)
            subprocess.run(["git", "add", "."], cwd=root, check=True, env=git_env)
            subprocess.run(["git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                            "commit", "-qm", "baseline"], cwd=root, check=True, env=git_env)
            base = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True, env=git_env).strip()
            changed.write_text("let after = 1\n")
            subprocess.run(["git", "add", "MarkView/Changed.swift"], cwd=root, check=True, env=git_env)
            subprocess.run(["git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                            "commit", "-qm", "change"], cwd=root, check=True, env=git_env)
            log = root / "build.log"
            log.write_text("\n".join(f"SwiftCompile normal arm64 {path} (in target 'MarkView' from project 'MarkView')"
                                     for path in (changed, dependent)))
            bindir = root / "bin"
            bindir.mkdir()
            fake = bindir / "swiftlint"
            fake.write_text('''#!/usr/bin/env python3
import json, os, sys
path = sys.argv[-1]
diagnostics = [{'file': path, 'rule_id': 'unused_import'}] if path.endswith('Dependent.swift') and os.environ.get('FAKE_DEPENDENT_WARNING') else []
print(json.dumps(diagnostics))
print('Done analyzing! Found 0 violations in 1 file.', file=sys.stderr)
''')
            fake.chmod(0o755)
            env = dict(os.environ, PATH=str(bindir) + os.pathsep + os.environ["PATH"])
            cmd = ["python3", str(root / "tools/ci/unused-import-changes.py"), "--base", base, "--compiler-log", str(log)]
            clean = subprocess.run(cmd, cwd=root, env=env, capture_output=True, text=True)
            self.assertEqual(clean.returncode, 0, clean.stderr)
            self.assertIn("2 changed or compiler-selected", clean.stdout)
            warning = subprocess.run(cmd, cwd=root, env=dict(env, FAKE_DEPENDENT_WARNING="1"), capture_output=True, text=True)
            self.assertNotEqual(warning.returncode, 0)
            self.assertIn("Dependent.swift: unused_import: 1 exceeds 0", warning.stderr)
            log.write_text("build log without compiler entries\n")
            missing = subprocess.run(cmd, cwd=root, env=env, capture_output=True, text=True)
            self.assertNotEqual(missing.returncode, 0)
            self.assertIn("no app/package SwiftCompile source entries", missing.stderr)


if __name__ == "__main__":
    unittest.main()
