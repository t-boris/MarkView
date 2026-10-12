#!/bin/bash
# Checks how a cloud place's CLI output (Firebase, Fly, Vercel) becomes a list of services with state, log command and
# links (MarkView/Models/CloudServices.swift), and that nothing but the chosen fields is read.
#   tools/tests/cloud-services-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/CloudServicesTests.swift "$out/main.swift"
swiftc -O -o "$out/cloud-services-tests" MarkView/Models/DeploymentModels.swift MarkView/Models/CommandPolicy.swift MarkView/Models/CloudServices.swift "$out/main.swift"
"$out/cloud-services-tests"
