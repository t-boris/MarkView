#!/bin/bash
# Checks who owns the work the X-Ray starts (AR-19): the shipping ArchitectureStore with its ChangeReviewStore and XRayFilterStore, the
# shipping CodeExplainStore and CodeNavigationStore, over real temporary git projects. The assistant is a stand-in that waits for the check
# to answer, fail or cancel it, and the project database is a stand-in that counts what is saved to it. MarkViewCore is built as the module
# the app links. No assistant is asked and no setting is read.
#   tools/tests/xray-task-ownership-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
target="$(uname -m)-apple-macos13.0"
swiftc -parse-as-library -wmo -target "$target" -module-name MarkViewCore -emit-module -emit-module-path "$out/MarkViewCore.swiftmodule" \
    -c Packages/MarkViewCore/Sources/MarkViewCore/*.swift -o "$out/MarkViewCore.o"
A=MarkView/Models/Architecture
architecture=()
for file in $A/*.swift; do
    case "$file" in
        */CodeAndXRayCoordinator.swift|*/SemanticDatabase+Architecture.swift|*/StructuralIndexer.swift|*/ProjectChangeReview*.swift) ;;
        *) architecture+=("$file") ;;
    esac
done
cp tools/tests/XRayOwnershipTests.swift "$out/main.swift"
swiftc -O -target "$target" -I "$out" -o "$out/xray-task-ownership-tests" "$out/MarkViewCore.o" \
    "${architecture[@]}" MarkView/Models/AI/AIOperation.swift MarkView/Models/AI/OutputLanguage.swift MarkView/Models/Insight/SemanticUsage.swift \
    MarkView/Models/Git/GitHubClient.swift MarkView/Models/AI/DiagramAI.swift \
    MarkView/Models/Shared/FileType.swift MarkView/Models/Shared/FrontMatter.swift MarkView/Models/Shared/WikiLinkResolver.swift \
    MarkView/Models/ProjectOps/ProjectOperationDiscovery.swift MarkView/Models/Shared/ArchiveSupport.swift Packages/MarkViewCore/Tests/TestSupport/SemanticDatabaseTestSupport.swift tools/tests/XRayStoreStubs.swift "$out/main.swift"
"$out/xray-task-ownership-tests"
