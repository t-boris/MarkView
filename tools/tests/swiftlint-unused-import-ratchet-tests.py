#!/usr/bin/env python3
"""Exercise analyzer failure handling without requiring SourceKit or changing the baseline."""
import os
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


class ChangedSourcesTests(unittest.TestCase):
    def test_the_real_wrapper_analyzes_the_changed_files_only(self):
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
with open(os.environ['FAKE_ANALYZED'], 'a') as analyzed:
    analyzed.write(os.path.basename(path) + '\\n')
warn = os.environ.get('FAKE_WARNING', '')
diagnostics = [{'file': path, 'rule_id': 'unused_import'}] if warn and path.endswith(warn) else []
print(json.dumps(diagnostics))
print('Done analyzing! Found 0 violations in 1 file.', file=sys.stderr)
''')
            fake.chmod(0o755)
            analyzed = root / "analyzed.txt"
            env = dict(os.environ, PATH=str(bindir) + os.pathsep + os.environ["PATH"], FAKE_ANALYZED=str(analyzed))
            cmd = ["python3", str(root / "tools/ci/unused-import-changes.py"), "--base", base, "--compiler-log", str(log)]
            clean = subprocess.run(cmd, cwd=root, env=env, capture_output=True, text=True)
            self.assertEqual(clean.returncode, 0, clean.stderr)
            self.assertIn("Analyzing 1 changed app/package Swift files", clean.stdout)
            self.assertEqual(analyzed.read_text().split(), ["Changed.swift"], "a recompiled dependant is not analyzed")
            dependant = subprocess.run(cmd, cwd=root, env=dict(env, FAKE_WARNING="Dependent.swift"), capture_output=True, text=True)
            self.assertEqual(dependant.returncode, 0, dependant.stderr)
            changed_warning = subprocess.run(cmd, cwd=root, env=dict(env, FAKE_WARNING="Changed.swift"), capture_output=True, text=True)
            self.assertNotEqual(changed_warning.returncode, 0)
            self.assertIn("Changed.swift: unused_import: 1 exceeds 0", changed_warning.stderr)


if __name__ == "__main__":
    unittest.main()
