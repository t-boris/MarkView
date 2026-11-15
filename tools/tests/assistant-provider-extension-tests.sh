#!/bin/bash
# AR-35: a new assistant is one provider file and one line in the provider list. tools/tests/FakeAssistantProvider.swift is a
# provider that no app code knows; FakeAssistantProviderList.swift replaces the real list with the same list plus that one
# line. The suite checks the stored raw values of the real assistants and that the terminal profile, the usage reader, the
# hand-off prompts and the one-shot run use the fake provider.
#   tools/tests/assistant-provider-extension-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
providers=$(ls MarkView/Models/AI/Providers/*.swift | grep -v '/AssistantProviderList.swift$')
swiftc -parse-as-library -o "$out/assistant-provider-extension-tests" Packages/MarkViewCore/Sources/MarkViewCore/*.swift \
    $providers tools/tests/FakeAssistantProviderList.swift tools/tests/FakeAssistantProvider.swift \
    MarkView/Models/AI/CLICompletion.swift MarkView/Models/AI/ACPAssistant.swift MarkView/Models/AI/AgentProcesses.swift \
    MarkView/Models/Terminal/TerminalProfile.swift MarkView/Models/Lifecycle/HandoffPrompt.swift MarkView/Models/Lifecycle/DefinitionOfDone.swift MarkView/Models/Workspace/SchemaVersionedStore.swift \
    tools/tests/CLICompletionTestSupport.swift tools/tests/AssistantExtensionTests.swift
"$out/assistant-provider-extension-tests"
