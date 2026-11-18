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
check_count() {
    python3 - "$1" "$2" <<'PY'
import pathlib, re, sys
log = pathlib.Path(sys.argv[1]).read_text(errors="replace")
counts = [int(n) for n in re.findall(r"Executed (\d+) tests?, with", log)]
expected = int(sys.argv[2])
if not counts or max(counts) == 0 or (expected and max(counts) != expected):
    sys.exit(f"Hosted selection ran {max(counts, default=0)} tests; expected {expected or 'at least one'}")
PY
}
run_host() {
  MARKVIEW_SOCKET_DIR="$socket_dir" TEST_RUNNER_MARKVIEW_SOCKET_DIR="$socket_dir" xcodebuild -project MarkView.xcodeproj -scheme MarkView -configuration HostedTests \
    -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO -test-timeouts-enabled YES "$@" test
}
shard_host() {
  local group=$1 index=$2 count=$3
  shift 3
  run_host "$@" -enumerate-tests -test-enumeration-style flat -test-enumeration-format json \
    -test-enumeration-output-path "$socket_dir/tests.json"
  python3 tools/ci/hosted-test-shards.py "$socket_dir/tests.json" "$index" "$count" "$group" > "$socket_dir/selected.txt"
  local selected=()
  while IFS= read -r test_id; do selected+=("-only-testing:$test_id"); done < "$socket_dir/selected.txt"
  run_host "${selected[@]}" 2>&1 | tee "$socket_dir/shard.log"
  check_count "$socket_dir/shard.log" "${#selected[@]}"
}
general_options=(-only-testing:MarkViewHostedTests)
for class in UIStudioSessionHostTests CockpitRuntimeIntegrationHostTests ManualPrototypeLiveHostTests \
  TerminalLayoutHostTests TerminalLinkHostTests ManualRemoteProviderHostTests ManualProviderLiveHostTests \
  ManualUIStudioLiveHostTests ManualNativeQAHostTests WorkflowEditorLayoutHostTests ResearchMapWebHostTests \
  ThemeWebHostTests UIStudioWebHostTests WelcomeScreenHostTests ProjectAIChoiceHostTests RemoteWorkspaceHostTests \
  PersistentRemoteHostTests RemoteRelaySettingsHostTests SavedRemoteConnectionsHostTests CLICompletionTimeoutHostTests \
  AssistantExtensionHostTests ACPContinuationHostTests; do
  general_options+=("-skip-testing:MarkViewHostedTests/$class")
done
part="${MARKVIEW_QA_HOST_PART:-all}"
case "$part" in
  all) run_host "${general_options[@]}" 2>&1 | tee "$socket_dir/general.log"; check_count "$socket_dir/general.log" 0 ;;
  general) run_host "${general_options[@]}" -skip-testing:MarkViewHostedTests/EditorHostTests 2>&1 | tee "$socket_dir/general.log"; check_count "$socket_dir/general.log" 0 ;;
  general-[01]) shard_host general "${part#general-}" 2 "${general_options[@]}" -skip-testing:MarkViewHostedTests/EditorHostTests; exit ;;
  isolated) ;;
  editor) run_host -only-testing:MarkViewHostedTests/EditorHostTests 2>&1 | tee "$socket_dir/editor.log"; check_count "$socket_dir/editor.log" 0; exit ;;
  editor-[0-3]) shard_host editor "${part#editor-}" 4 -only-testing:MarkViewHostedTests/EditorHostTests; exit ;;
  *) echo "Unknown QA host part: $part" >&2; exit 2 ;;
esac
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
