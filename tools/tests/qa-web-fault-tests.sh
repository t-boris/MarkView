#!/bin/bash
# Real app-hosted WebKit fault filtering and editor rendering, with production types.
set -euo pipefail
cd "$(dirname "$0")/../.."
# UI Studio's hosted lifetime scenarios start local Python servers; avoid slow loopback reverse DNS.
export PYTHONPATH="$PWD/tools/tests/studio-python${PYTHONPATH:+:$PYTHONPATH}"
export PYTHONDONTWRITEBYTECODE=1
export TEST_RUNNER_PYTHONPATH="$PYTHONPATH"
export TEST_RUNNER_PYTHONDONTWRITEBYTECODE=1
unset MARKVIEW_STUDIO_LIFETIME_FILTER TEST_RUNNER_MARKVIEW_STUDIO_LIFETIME_FILTER
derived="${MARKVIEW_HOSTED_TEST_DERIVED_DATA:-${TMPDIR:-/tmp}/MarkViewHostedTestsDerived}"
socket_dir=$(mktemp -d /tmp/mvhost.XXXXXX)
trap 'rm -rf "$socket_dir"' EXIT
MARKVIEW_SOCKET_DIR="$socket_dir" TEST_RUNNER_MARKVIEW_SOCKET_DIR="$socket_dir" xcodebuild -project MarkView.xcodeproj -scheme MarkView -configuration HostedTests \
  -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO \
  -test-timeouts-enabled YES \
  -only-testing:MarkViewHostedTests -skip-testing:MarkViewHostedTests/UIStudioSessionHostTests \
  -skip-testing:MarkViewHostedTests/CockpitRuntimeIntegrationHostTests \
  -skip-testing:MarkViewHostedTests/ManualPrototypeLiveHostTests \
  -skip-testing:MarkViewHostedTests/ManualRemoteProviderHostTests \
  -skip-testing:MarkViewHostedTests/ManualProviderLiveHostTests \
  -skip-testing:MarkViewHostedTests/ManualUIStudioLiveHostTests \
  -skip-testing:MarkViewHostedTests/ManualNativeQAHostTests \
  -skip-testing:MarkViewHostedTests/WorkflowEditorLayoutHostTests \
  -skip-testing:MarkViewHostedTests/ResearchMapWebHostTests \
  -skip-testing:MarkViewHostedTests/ThemeWebHostTests \
  -skip-testing:MarkViewHostedTests/UIStudioWebHostTests \
  -skip-testing:MarkViewHostedTests/WelcomeScreenHostTests \
  -skip-testing:MarkViewHostedTests/ProjectAIChoiceHostTests \
  -skip-testing:MarkViewHostedTests/RemoteWorkspaceHostTests \
  -skip-testing:MarkViewHostedTests/PersistentRemoteHostTests \
  -skip-testing:MarkViewHostedTests/RemoteRelaySettingsHostTests \
  -skip-testing:MarkViewHostedTests/SavedRemoteConnectionsHostTests \
  -skip-testing:MarkViewHostedTests/CLICompletionTimeoutHostTests \
  -skip-testing:MarkViewHostedTests/AssistantExtensionHostTests \
  -skip-testing:MarkViewHostedTests/ACPContinuationHostTests test
# The workspace test owns a process registry and runs in a fresh host.
bash tools/tests/remote-workspace-host-tests.sh
# Write and read the temporary relay credentials in separate isolated hosts.
bash tools/tests/remote-relay-settings-tests.sh
# Exercise saved pairings against an isolated Keychain service and offline relay.
bash tools/tests/saved-remote-connections-host-tests.sh
# Exercise persistent terminals with an isolated relay and local echo executable.
bash tools/tests/persistent-remote-host-tests.sh
# Run fake CLI processes with a separate home and child registry.
bash tools/tests/cli-completion-timeout-host-tests.sh
# Run ACP continuation and permission checks in their own isolated host.
bash tools/tests/cli-completion-timeout-host-tests.sh --continuation
# Exercise the fake extension provider in a separate temporary-home host.
bash tools/tests/cli-completion-timeout-host-tests.sh --extension
