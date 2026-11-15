#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
if [ -z "${MARKVIEW_TEST_RUNTIME:-}" ]; then
    runtime_stage="$out/runtime-stage"
    TARGET_BUILD_DIR="$runtime_stage" UNLOCALIZED_RESOURCES_FOLDER_PATH="MarkView.app/Contents/Resources" CONFIGURATION="Debug" \
        tools/cockpit-temporal/scripts/build-runtime.sh
    export MARKVIEW_TEST_RUNTIME="$runtime_stage/MarkView.app/Contents/Resources/Cockpit/arm64"
fi
python3 - "$out/ProcessRunner.swift" <<'PY'
from pathlib import Path
import sys
source = Path('MarkView/Models/DeploymentExecutor.swift').read_text()
Path(sys.argv[1]).write_text(source.split('protocol DeploymentExecutor')[0])
PY
swiftc -parse-as-library -o "$out/checks" "$out/ProcessRunner.swift" MarkView/Models/AgentProcesses.swift MarkView/Models/CockpitPlan.swift MarkView/Models/CockpitRun.swift MarkView/Models/CockpitRunStore.swift MarkView/Models/CockpitSupervisor.swift MarkView/Models/CockpitStepMeter.swift MarkView/Models/CockpitChild.swift MarkView/Models/CockpitHostBridge.swift MarkView/Models/CockpitRuntime.swift MarkView/Models/CockpitExecution.swift tools/tests/CockpitRuntimeChecks.swift
"$out/checks"
