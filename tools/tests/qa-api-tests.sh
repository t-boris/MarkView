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
    "$M/QAAPI.swift" "$M/QAAPIClient.swift" "$M/QAAPIActor.swift" "$M/QAScenario.swift" "$M/QARun.swift" "$M/QAStore.swift" \
    "$M/QAGeneration.swift" "$M/QAGenerator.swift" "$M/QAPlan.swift" "$M/QAGate.swift" "$M/QAEffort.swift" \
    "$M/QATriage.swift" "$M/QAActions.swift" "$M/QARunner.swift" "$M/QALanguage.swift" "$M/QAPageEvidence.swift" \
    "$M/QACredentials.swift" tools/tests/QANativeKeychainStub.swift tools/tests/QAAPIChecks.swift
if [ -n "${QA_API_EXPORT_PROMPTS:-}" ]; then "$out/qa-api" --export "$QA_API_EXPORT_PROMPTS"; fi
"$out/qa-api" "http://127.0.0.1:$(cat "$out/port")" "${QA_API_GENERATED_SCENARIO:-Tests/Fixtures/qa-api-demo/scenario-proposal.json}"
