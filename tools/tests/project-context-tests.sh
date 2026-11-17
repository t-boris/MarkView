#!/bin/bash
# The open project of a window (MarkView/Models/Workspace/ProjectContext.swift, AR-14 step 8) on real folders, files and SQLite
# databases: folder open with exclusions and recents, linked folders, the database lifecycle of a folder and of a single file,
# and the stale-tree guard of the file tree store. Compiles the shipping ProjectContext, WorkspaceFileTreeStore, FileNode,
# LinkedFolders and SemanticDatabase; only unrelated model dependencies of the database are stubbed.
#   tools/tests/project-context-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -parse-as-library -o "$out/project-context-tests" \
    Packages/MarkViewCore/Sources/MarkViewCore/*.swift \
    MarkView/Models/Workspace/ProjectContext.swift MarkView/Models/Shared/UserPrompts.swift MarkView/Models/Shared/ProjectProviding.swift MarkView/Models/Workspace/WorkspaceFileTreeStore.swift MarkView/Models/Workspace/FileNode.swift tools/tests/ScriptedPrompts.swift \
    MarkView/Models/Workspace/ExcludedFolders.swift MarkView/Models/Shared/LinkedFolders.swift MarkView/Models/Shared/LinkedFolderStore.swift MarkView/Models/Shared/SchemaVersionedStore.swift \
    MarkView/Models/Appearance/ProjectColor.swift \
    MarkView/Models/Shared/SemanticDatabase.swift MarkView/Models/Shared/SemanticSchema.swift MarkView/Models/Shared/SemanticModels.swift \
    MarkView/Models/Architecture/ArchitectureModel.swift MarkView/Models/Architecture/CodeArchitecture.swift \
    MarkView/Models/Architecture/CodePathTags.swift  \
    MarkView/Models/AI/DiagramAI.swift MarkView/Models/AI/AIOperation.swift tools/tests/DiagramCLIStub.swift tools/tests/SemanticDatabaseTestSupport.swift \
    tools/tests/ProjectContextTests.swift
"$out/project-context-tests"
