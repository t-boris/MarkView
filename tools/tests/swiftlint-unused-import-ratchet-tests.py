#!/usr/bin/env python3
"""Exercise analyzer failure handling without requiring SourceKit or changing the baseline."""
import os
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
CHECK = ROOT / "tools/lint/swiftlint-unused-import-ratchet.py"
SOURCE = "Packages/MarkViewCore/Sources/MarkViewCore/AnyCodable.swift"


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


if __name__ == "__main__":
    unittest.main()
