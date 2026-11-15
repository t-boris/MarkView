#!/bin/bash
# The open project of a window (MarkView/Models/Workspace/ProjectContext.swift, AR-14 step 8) on real folders, files and SQLite
# databases: folder open with exclusions and recents, linked folders, the database lifecycle of a folder and of a single file,
# and the stale-tree guard of the file tree store. Compiles the shipping ProjectContext, WorkspaceFileTreeStore, FileNode,
# LinkedFolders and SemanticDatabase; only the unrelated model dependencies of the database are stubbed (as in semantic-database-tests).
#   tools/tests/project-context-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -parse-as-library -o "$out/project-context-tests" \
    Packages/MarkViewCore/Sources/MarkViewCore/*.swift \
    MarkView/Models/Workspace/SchemaVersionedStore.swift MarkView/Models/Workspace/ProjectContext.swift MarkView/Models/Workspace/WorkspaceFileTreeStore.swift MarkView/Models/Workspace/FileNode.swift \
    MarkView/Models/Workspace/ExcludedFolders.swift MarkView/Models/Workspace/LinkedFolders.swift MarkView/Models/Workspace/TaskBag.swift \
    MarkView/Models/Appearance/ProjectColor.swift MarkView/Models/Workspace/BackgroundFileScans.swift \
    MarkView/Models/Insight/SemanticDatabase.swift MarkView/Models/Insight/SemanticSchema.swift MarkView/Models/Insight/SemanticModels.swift \
    MarkView/Models/Architecture/ArchitectureModel.swift MarkView/Models/Architecture/CodeArchitecture.swift \
    MarkView/Models/Architecture/CodePathTags.swift MarkView/Models/Architecture/AutoAnalysisScheduler.swift \
    MarkView/Models/AI/DiagramAI.swift MarkView/Models/AI/AIOperation.swift tools/tests/DiagramCLIStub.swift tools/tests/SemanticDatabaseTestSupport.swift \
    tools/tests/ProjectContextTests.swift
"$out/project-context-tests"
