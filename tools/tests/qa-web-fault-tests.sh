#!/bin/bash
# Real WebKit fetch/XHR fault filtering, request forwarding and player isolation.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
M=MarkView/Models
swiftc -parse-as-library -o "$out/qa-web-fault" \
  "$M/QAWebActor.swift" "$M/QAWebWindow.swift" \
  "$M/QAAPI.swift" "$M/QAScenario.swift" "$M/QARun.swift" "$M/QAStore.swift" \
  "$M/QAGeneration.swift" "$M/QAGenerator.swift" "$M/QAPlan.swift" "$M/QAGate.swift" \
  "$M/QAEffort.swift" "$M/QATriage.swift" "$M/QAActions.swift" "$M/QARunner.swift" \
  "$M/QALanguage.swift" "$M/QAPageEvidence.swift" "$M/QACredentials.swift" \
  "$M/QAScenarioEdit.swift" "$M/QAAttachments.swift" "$M/QAGraphLayout.swift" \
  tools/tests/IssueChecksSupport.swift tools/tests/QANativeKeychainStub.swift tools/tests/QAWebFaultChecks.swift
"$out/qa-web-fault"
