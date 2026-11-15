#!/bin/bash
# The state database (.dde/state.db) on real SQLite files (AR-38, AR-37): a new file, a file written by release 6.26.x
# (built from the frozen create statements of that release), an older release's table set, the unversioned file that
# predates the docId scheme, a file from a newer release, and a corrupt file. Compiles the shipping SemanticDatabase,
# SemanticSchema and MarkViewCore's SQLiteSchema with the real architecture models, and the StructuralIndexer that fills it
# (its progress callback, a second run over an unchanged folder).
#   tools/tests/semantic-database-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/SemanticDatabaseTests.swift "$out/main.swift"
swiftc -O -o "$out/check" \
    Packages/MarkViewCore/Sources/MarkViewCore/*.swift \
    MarkView/Models/Insight/SemanticDatabase.swift MarkView/Models/Insight/SemanticSchema.swift MarkView/Models/Insight/SemanticModels.swift \
    MarkView/Models/Architecture/ArchitectureModel.swift MarkView/Models/Architecture/CodeArchitecture.swift \
    MarkView/Models/Architecture/CodePathTags.swift MarkView/Models/Architecture/AutoAnalysisScheduler.swift \
    MarkView/Models/AI/DiagramAI.swift MarkView/Models/AI/AIOperation.swift tools/tests/DiagramCLIStub.swift tools/tests/SemanticDatabaseTestSupport.swift \
    MarkView/Models/Architecture/StructuralIndexer.swift MarkView/Models/Workspace/LinkedFolders.swift MarkView/Models/Appearance/ProjectColor.swift "$out/main.swift"
"$out/check" "$PWD/tools/tests/fixtures/semantic-database/release-6.26-schema.sql"
