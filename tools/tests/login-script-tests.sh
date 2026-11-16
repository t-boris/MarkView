#!/bin/bash
# Checks the sign-in scripts MarkView hands to Terminal.app (MarkView/Models/AI/LoginScript.swift, used by `claude login` and
# `gh auth login`): the script is saved whole and executable, an old one is replaced whole, and a folder that refuses it keeps the old one.
#   tools/tests/login-script-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/LoginScriptTests.swift "$out/main.swift"
swiftc -O -o "$out/login-script-tests" Packages/MarkViewCore/Sources/MarkViewCore/CoreFiles.swift MarkView/Models/AI/LoginScript.swift "$out/main.swift"
# CFFIXED_USER_HOME moves the home folder into the scratch folder: the person's own scripts are never touched.
CFFIXED_USER_HOME="$out/home" "$out/login-script-tests"
