#!/bin/bash
# Real WebKit fetch/XHR fault filtering, request forwarding and player isolation.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
M=MarkView/Models
swiftc -parse-as-library -o "$out/qa-web-fault" \
  "$M/QA/QAWebActor.swift" "MarkView/Views/QA/QAWebWindow.swift" \
  "$M/QA/QAAPI.swift" "$M/QA/QAScenario.swift" "$M/QA/QARun.swift" "$M/QA/QAStore.swift" MarkView/Models/Workspace/SchemaVersionedStore.swift Packages/MarkViewCore/Sources/MarkViewCore/AppLog.swift Packages/MarkViewCore/Sources/MarkViewCore/CoreFiles.swift \
  "$M/QA/QAGeneration.swift" "$M/QA/QAGenerator.swift" "$M/QA/QAPlan.swift" "$M/QA/QAGate.swift" \
  "$M/QA/QAEffort.swift" "$M/QA/QATriage.swift" "$M/QA/QAInputMark.swift" "$M/QA/QAActions.swift" "$M/QA/QARunner.swift" \
  "$M/QA/QALanguage.swift" "$M/QA/QAPageEvidence.swift" "$M/QA/QACredentials.swift" \
  "$M/QA/QAScenarioEdit.swift" "$M/QA/QAAttachments.swift" "$M/QA/QAGraphLayout.swift" \
  tools/tests/IssueChecksSupport.swift tools/tests/QANativeKeychainStub.swift tools/tests/QAWebFaultChecks.swift
"$out/qa-web-fault"
