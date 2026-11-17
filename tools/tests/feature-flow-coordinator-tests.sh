#!/bin/bash
# The feature flow of a window (AR-14 step 9): the shipping FeatureFlowCoordinator (intake, "Implement with AI", "Fix with AI", the bug
# basket, hand-off resume, the GitHub tabs, checkout and issue branches, the Settings switch and the coordinator's own task bag) over real
# temporary folders and git repositories, with the real panels, window chrome, batch rules, prompts, GitHub client and Git status. The
# stores, the terminals, the tabs and the research jobs are compile-time stand-ins that record what the coordinator asks of them
# (FeatureFlowCoordinatorStubs.swift). `gh` is never run, nothing is shown, typed or sent; the test process has its own UserDefaults domain.
#   tools/tests/feature-flow-coordinator-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
# A few real declarations are compiled without the files around them: the intake request, the hand-off resume and the GitHub settings keys.
python3 - "$out" <<'PY'
import pathlib, sys
out = pathlib.Path(sys.argv[1])
intake = pathlib.Path('MarkView/Models/Lifecycle/FeatureIntake.swift').read_text()
requests = intake.split('enum IntakeKind:')[1].split('extension FeatureAssistant {')[0]
(out / 'IntakeRequest.swift').write_text('import Foundation\nenum IntakeKind:' + requests)
handoff = pathlib.Path('MarkView/Models/Lifecycle/SpecificationHandoff.swift').read_text()
resume = handoff.split('struct HandoffResume {')[1].split('\n}\n')[0]
(out / 'HandoffResume.swift').write_text('import Foundation\nstruct HandoffResume {' + resume + '\n}\n')
store = pathlib.Path('MarkView/Models/Git/GitHubStore.swift').read_text()
settings = store.split('enum GitHubSettings {')[1].split('/// GitHub state of one window')[0]
(out / 'GitHubSettings.swift').write_text('import Foundation\nenum GitHubSettings {' + settings)
PY
cp tools/tests/FeatureFlowCoordinatorTests.swift "$out/FeatureFlowCoordinatorTests.swift"
swiftc -parse-as-library -target "$(uname -m)-apple-macos13.0" -o "$out/feature-flow-coordinator-tests" \
    Packages/MarkViewCore/Sources/MarkViewCore/*.swift \
    MarkView/Models/Workspace/FeatureFlowCoordinator.swift MarkView/Models/Lifecycle/BugBasket.swift MarkView/Models/Lifecycle/HandoffPrompt.swift \
    MarkView/Models/Lifecycle/DefinitionOfDone.swift MarkView/Models/Lifecycle/IssueListing.swift MarkView/Models/Lifecycle/EvidenceTimings.swift \
    MarkView/Models/Lifecycle/LifecycleCapture.swift MarkView/Models/Git/GitHubClient.swift MarkView/Models/Git/GitStatusModel.swift \
    MarkView/Models/Terminal/AssistantProviding.swift MarkView/Models/Terminal/TerminalProfile.swift \
    MarkView/Models/Shared/ProjectProviding.swift \
    MarkView/Models/AI/Providers/*.swift \
    MarkView/Models/Appearance/AppTheme.swift MarkView/Models/Appearance/ThemeDefinition.swift MarkView/Models/Appearance/ThemeCatalog.swift \
    MarkView/Models/Appearance/WelcomeBackdrop.swift MarkView/Models/Appearance/BackdropRegistry.swift MarkView/Models/Appearance/ProjectBackdrop.swift \
    MarkView/Models/Workspace/PanelLayout.swift MarkView/Models/Shared/SchemaVersionedStore.swift MarkView/Models/Workspace/ToolRegistry.swift \
    MarkView/Models/Workspace/WindowSession.swift MarkView/Models/Workspace/WindowUIState.swift MarkView/Models/Workspace/WindowChrome.swift \
    MarkView/Models/Git/GitHubItem.swift "$out/IntakeRequest.swift" "$out/HandoffResume.swift" "$out/GitHubSettings.swift" \
    tools/tests/ProjectProvidingTestSupport.swift Packages/MarkViewCore/Tests/TestSupport/SemanticDatabaseTestSupport.swift tools/tests/FeatureFlowCoordinatorStubs.swift "$out/FeatureFlowCoordinatorTests.swift" 2>&1 | head -80
cp -R MarkView/Resources/Themes "$out/Themes"
"$out/feature-flow-coordinator-tests"
