#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${MARKVIEW_TEST_RUNTIME:?Path to packaged runtime architecture directory}"
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
python3 - "$out/ProcessRunner.swift" <<'PY'
from pathlib import Path
import sys
source = Path('MarkView/Models/DeploymentExecutor.swift').read_text()
Path(sys.argv[1]).write_text(source.split('protocol DeploymentExecutor')[0])
PY
swiftc -parse-as-library -o "$out/checks" "$out/ProcessRunner.swift" MarkView/Models/AgentProcesses.swift MarkView/Models/CockpitPlan.swift MarkView/Models/CockpitRun.swift MarkView/Models/CockpitRunStore.swift MarkView/Models/CockpitSupervisor.swift MarkView/Models/CockpitStepMeter.swift MarkView/Models/CockpitChild.swift MarkView/Models/CockpitHostBridge.swift MarkView/Models/CockpitRuntime.swift MarkView/Models/CockpitExecution.swift tools/tests/CockpitRuntimeChecks.swift
"$out/checks"
