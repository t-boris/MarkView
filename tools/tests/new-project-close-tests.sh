#!/bin/bash
# What closing the Start a Project from Scratch sheet does to the work it started (AR-19): the shipping NewProjectFlow over the shipping
# FeatureStore, FeatureAssistant, FeatureJobs and TaskBag. A job started through the assistant is refused a second start and restarts when
# it ended, a close cuts off the running job and the step in flight without a write after it, and a job that wakes after the sheet is gone
# still finds its store. MarkViewCore is built as the module the app links; the rest of the app's layers the flow needs (the assistants'
# calls, the GitHub client) are compiled as they ship and nothing is asked or saved: HOME is an empty folder.
#   tools/tests/new-project-close-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
target="$(uname -m)-apple-macos13.0"
swiftc -parse-as-library -wmo -target "$target" -module-name MarkViewCore -emit-module -emit-module-path "$out/MarkViewCore.swiftmodule" \
    -c Packages/MarkViewCore/Sources/MarkViewCore/*.swift -o "$out/MarkViewCore.o"
M=MarkView/Models
swiftc -parse-as-library -Onone -target "$target" -I "$out" -o "$out/new-project-close-tests" "$out/MarkViewCore.o" \
    $M/Lifecycle/*.swift $M/Shared/*.swift $M/AI/*.swift $M/AI/Providers/*.swift \
    $M/Workspace/NewProjectFlow.swift $M/Workspace/ProjectBootstrap.swift $M/Workspace/NewProject.swift $M/Workspace/ProjectDraftStore.swift \
    $M/Git/GitHubClient.swift $M/Git/GitHubStore.swift $M/Dictation/WhisperClient.swift $M/Dictation/OnDeviceSpeech.swift \
    Packages/MarkViewCore/Sources/MarkViewCore/RecordingLevel.swift $M/Insight/SemanticUsage.swift $M/Appearance/ProjectColor.swift tools/tests/NewProjectCloseChecks.swift
mkdir "$out/home"
HOME="$out/home" "$out/new-project-close-tests"
