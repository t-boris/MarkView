#!/bin/bash
# The tools of a window (AR-14 step 10): the shipping ToolTabsRouter opens every tool of ToolRegistry on the real tabs controller, panels,
# deployment store and discussion store of a temporary project, and the shipping Discussions, Deployments, UI Studio, Cockpit and Prototype
# Studio hosts do their own work (an answer streaming into a discussion and ending with the window, the usage record, the sessions of
# the tabs). The QA model, the Feature store, the sessions the tabs carry and the assistant run are compile-time stand-ins.
#   tools/tests/tool-tabs-router-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -target "$(uname -m)-apple-macos13.0" -parse-as-library -o "$out/tool-tabs-router-tests" \
    Packages/MarkViewCore/Sources/MarkViewCore/*.swift \
    MarkView/Models/Appearance/AppTheme.swift MarkView/Models/Appearance/ThemeDefinition.swift MarkView/Models/Appearance/ThemeCatalog.swift \
    MarkView/Models/Appearance/WelcomeBackdrop.swift MarkView/Models/Appearance/BackdropRegistry.swift MarkView/Models/Appearance/ProjectBackdrop.swift \
    MarkView/Models/Workspace/DocumentState.swift MarkView/Models/Architecture/XRayScope.swift MarkView/Models/Git/GitHubItem.swift MarkView/Models/Shared/ArchiveSupport.swift MarkView/Models/Shared/FileType.swift MarkView/Models/Workspace/ToolRegistry.swift \
    MarkView/Models/Workspace/EditorDocumentRouting.swift \
    MarkView/Models/Workspace/DocumentScrollSideTable.swift MarkView/Models/Workspace/TabsController.swift MarkView/Models/Shared/UserPrompts.swift \
    MarkView/Models/Workspace/PanelLayout.swift MarkView/Models/Shared/SchemaVersionedStore.swift MarkView/Models/Workspace/WindowSession.swift \
    MarkView/Models/Workspace/WindowUIState.swift MarkView/Models/Workspace/WindowChrome.swift MarkView/Models/Shared/ProjectProviding.swift \
    MarkView/Models/Workspace/ToolOpener.swift MarkView/Models/Workspace/ToolTabsRouter.swift MarkView/Models/Terminal/AssistantProviding.swift \
    MarkView/Models/Book/PDFReader.swift MarkView/Models/AI/OutputLanguage.swift MarkView/Models/AI/AIOperation.swift \
    MarkView/Models/Deployments/DeploymentModels.swift MarkView/Models/Deployments/SystemProbe.swift \
    MarkView/Models/Deployments/DeploymentDiscovery.swift MarkView/Models/Deployments/DeploymentExecutor.swift \
    MarkView/Models/Deployments/DeploymentLogs.swift MarkView/Models/Deployments/CloudServices.swift MarkView/Models/AI/ProviderHints.swift \
    MarkView/Models/Deployments/DeploymentStore.swift MarkView/Models/Deployments/DeploymentStore+Databases.swift \
    MarkView/Models/Deployments/DatabaseExplorer.swift MarkView/Models/Deployments/DatabaseKeychain.swift \
    MarkView/Models/Deployments/DeploymentAdvisor.swift MarkView/Models/Deployments/DeploymentsHost.swift \
    MarkView/Models/Discussion/Discussion.swift MarkView/Models/Discussion/DiscussionPrompt.swift MarkView/Models/Discussion/DiscussionsHost.swift \
    MarkView/Models/Workspace/UIStudioHost.swift MarkView/Models/Workspace/CockpitHost.swift \
    MarkView/Models/Prototype/PrototypeFiles.swift MarkView/Models/Workspace/PrototypeStudioHost.swift \
    tools/tests/ToolTabsRouterStubs.swift tools/tests/ProjectProvidingTestSupport.swift tools/tests/ToolTabsRouterTests.swift
"$out/tool-tabs-router-tests"
