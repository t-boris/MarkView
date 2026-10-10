#!/bin/bash
# Checks the machine probe of Deployments (MarkView/Models/SystemProbe.swift): the parser, the health
# rules, the quoting, and the real script on this machine.
#   tools/tests/system-probe-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/SystemProbeTests.swift "$out/main.swift"
swiftc -O -o "$out/system-probe-tests" MarkView/Models/CommandPolicy.swift MarkView/Models/DeploymentModels.swift MarkView/Models/SystemProbe.swift "$out/main.swift"
"$out/system-probe-tests"
