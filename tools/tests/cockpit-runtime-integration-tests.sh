#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
if [ -z "${MARKVIEW_TEST_RUNTIME:-}" ]; then
    if [ "${CI:-}" = "true" ] && [ "${MARKVIEW_BUILD_COCKPIT_RUNTIME:-0}" != "1" ]; then
        echo "Cockpit runtime is checked separately in CI (copilot-cockpit.yml)"
        exit 0
    fi
    for candidate in \
        "$PWD/build/DerivedData/Build/Products/Debug/MarkView.app/Contents/Resources/Cockpit/arm64" \
        "/tmp/MarkViewDerivedData/Build/Products/Debug/MarkView.app/Contents/Resources/Cockpit/arm64"; do
        if [ -x "$candidate/bin/server" ]; then
            export MARKVIEW_TEST_RUNTIME="$candidate"
            break
        fi
    done
    if [ -z "${MARKVIEW_TEST_RUNTIME:-}" ]; then
        runtime_stage="$out/runtime-stage"
        TARGET_BUILD_DIR="$runtime_stage" UNLOCALIZED_RESOURCES_FOLDER_PATH="MarkView.app/Contents/Resources" CONFIGURATION="Debug" \
            tools/cockpit-temporal/scripts/build-runtime.sh
        export MARKVIEW_TEST_RUNTIME="$runtime_stage/MarkView.app/Contents/Resources/Cockpit/arm64"
    fi
fi
python3 - "$out/ProcessRunner.swift" <<'PY'
from pathlib import Path
import sys
source = Path('MarkView/Models/Deployments/DeploymentExecutor.swift').read_text()
Path(sys.argv[1]).write_text(source.split('protocol DeploymentExecutor')[0])
PY
swiftc -parse-as-library -o "$out/checks" "$out/ProcessRunner.swift" MarkView/Models/AI/AgentProcesses.swift MarkView/Models/Cockpit/CockpitPlan.swift MarkView/Models/Cockpit/CockpitRun.swift MarkView/Models/Cockpit/CockpitRunStore.swift MarkView/Models/Workspace/SchemaVersionedStore.swift Packages/MarkViewCore/Sources/MarkViewCore/CoreFiles.swift MarkView/Models/Cockpit/CockpitSupervisor.swift MarkView/Models/Cockpit/CockpitStepMeter.swift MarkView/Models/Cockpit/CockpitChild.swift Packages/MarkViewCore/Sources/MarkViewCore/PrivateSocket.swift MarkView/Models/Cockpit/CockpitHostBridge.swift MarkView/Models/Cockpit/CockpitRuntime.swift MarkView/Models/Cockpit/CockpitExecution.swift tools/tests/CockpitRuntimeChecks.swift
"$out/checks"
