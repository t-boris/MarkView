#!/bin/bash
# Real HTTP API requests, replay, deterministic assertions, auth isolation and runner outcomes.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
pid=""
cleanup() { if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi; rm -rf "$out"; }
trap cleanup EXIT
python3 Tests/Fixtures/qa-api-demo/server.py "$out/port" &
pid=$!
for _ in {1..50}; do [ -s "$out/port" ] && break; sleep 0.1; done
M=MarkView/Models
swiftc -parse-as-library -o "$out/qa-api" \
    "$M/QA/QAAPI.swift" "$M/QA/QAAPIClient.swift" "$M/QA/QAAPIActor.swift" "$M/QA/QAScenario.swift" "$M/QA/QARun.swift" "$M/QA/QAStore.swift" MarkView/Models/Shared/SchemaVersionedStore.swift Packages/MarkViewCore/Sources/MarkViewCore/AppLog.swift Packages/MarkViewCore/Sources/MarkViewCore/StoredJSON.swift Packages/MarkViewCore/Sources/MarkViewCore/CoreFiles.swift \
    "$M/QA/QAGeneration.swift" "$M/QA/QAGenerator.swift" "$M/AI/AIOperation.swift" tools/tests/AIOperationStub.swift "$M/QA/QAPlan.swift" "$M/QA/QAGate.swift" "$M/QA/QAEffort.swift" \
    "$M/QA/QATriage.swift" "$M/QA/QAInputMark.swift" "$M/QA/QAActions.swift" "$M/QA/QARunner.swift" "$M/QA/QALanguage.swift" "$M/QA/QAPageEvidence.swift" \
    "$M/QA/QACredentials.swift" tools/tests/QANativeKeychainStub.swift tools/tests/QAAPIChecks.swift
if [ -n "${QA_API_EXPORT_PROMPTS:-}" ]; then "$out/qa-api" --export "$QA_API_EXPORT_PROMPTS"; fi
"$out/qa-api" "http://127.0.0.1:$(cat "$out/port")" "${QA_API_GENERATED_SCENARIO:-Tests/Fixtures/qa-api-demo/scenario-proposal.json}"
