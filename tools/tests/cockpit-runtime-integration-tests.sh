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
        # A runtime built before the last change to the Go sources is stale: use it only when it is newer than every source.
        if [ -x "$candidate/bin/server" ] && [ -z "$(find tools/cockpit-temporal -name '*.go' -newer "$candidate/bin/server" -print -quit)" ]; then
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
swiftc -parse-as-library -o "$out/checks" Packages/MarkViewCore/Sources/MarkViewCore/*.swift MarkView/Models/AI/AgentProcesses.swift MarkView/Models/Cockpit/CockpitPlan.swift MarkView/Models/Cockpit/CockpitRun.swift MarkView/Models/Cockpit/CockpitRunStore.swift MarkView/Models/Workspace/SchemaVersionedStore.swift MarkView/Models/Cockpit/CockpitSupervisor.swift MarkView/Models/Cockpit/CockpitStepMeter.swift MarkView/Models/Cockpit/CockpitChild.swift MarkView/Models/Cockpit/CockpitHostBridge.swift MarkView/Models/Cockpit/CockpitRuntime.swift MarkView/Models/Cockpit/CockpitExecution.swift tools/tests/CockpitRuntimeChecks.swift
"$out/checks"
