#!/bin/bash
# The schema of the feature and bug files (AR-39): the shipping FeatureStore over real files in a temporary project. A file written before
# the schema existed loads unchanged and gets `schema: 1` on its next write, whatever the write is (an overview, an object, a bug report,
# many objects at once, a plan); a file of a newer schema is never rewritten and the store says why; a new object carries the schema.
# MarkViewCore is built as the module the app links; HOME is an empty folder, so no setting of the person is read or written.
#   tools/tests/feature-store-schema-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
target="$(uname -m)-apple-macos13.0"
swiftc -parse-as-library -wmo -target "$target" -module-name MarkViewCore -emit-module -emit-module-path "$out/MarkViewCore.swiftmodule" \
    -c Packages/MarkViewCore/Sources/MarkViewCore/*.swift -o "$out/MarkViewCore.o"
M=MarkView/Models
swiftc -parse-as-library -Onone -target "$target" -I "$out" -o "$out/feature-store-schema-tests" "$out/MarkViewCore.o" \
    $M/Lifecycle/*.swift $M/Shared/*.swift $M/AI/*.swift $M/AI/Providers/*.swift \
    $M/Workspace/NewProjectFlow.swift $M/Workspace/ProjectBootstrap.swift $M/Workspace/NewProject.swift $M/Workspace/ProjectDraftStore.swift \
    $M/Git/GitHubClient.swift $M/Git/GitHubStore.swift $M/Dictation/WhisperClient.swift $M/Dictation/OnDeviceSpeech.swift \
    Packages/MarkViewCore/Sources/MarkViewCore/RecordingLevel.swift $M/Insight/SemanticUsage.swift $M/Appearance/ProjectColor.swift tools/tests/FeatureStoreSchemaChecks.swift
mkdir "$out/home"
HOME="$out/home" "$out/feature-store-schema-tests"
