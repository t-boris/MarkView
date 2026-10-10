#!/bin/bash
# Runs the Deployments ssh path against a private sshd on a high port with throwaway keys and its own
# known_hosts (nothing of the person's ~/.ssh is touched): host key refusal and trust, commands, the probe
# script, a refused key, a closed port. Skips when sshd cannot start.
#   tools/tests/deployment-ssh-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/DeploymentSSHTests.swift "$out/main.swift"
swiftc -O -o "$out/deployment-ssh-tests" MarkView/Models/CommandPolicy.swift MarkView/Models/DeploymentModels.swift MarkView/Models/SystemProbe.swift MarkView/Models/DeploymentExecutor.swift "$out/main.swift"
"$out/deployment-ssh-tests"
