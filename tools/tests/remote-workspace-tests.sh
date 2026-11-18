#!/bin/bash
# Direct invocation covers the isolated app-host workspace and the relay tests.
set -euo pipefail
cd "$(dirname "$0")/../.."
case "${1:-}" in
  --provider-command|--remote-workspace-mcp|--remote-workspace-guard)
    out=$(mktemp -d)
    trap 'rm -rf "$out"' EXIT
    swiftc -parse-as-library -module-cache-path "${TMPDIR:-/tmp}/markview-remote-test-modules" -o "$out/remote-workspace-tests" Packages/MarkViewCore/Sources/MarkViewCore/*.swift \
    MarkView/Models/Remote/RemoteProtocol.swift \
    MarkView/Models/Remote/RemoteFraming.swift \
    MarkView/Models/Remote/RemoteWorkspace.swift \
    MarkView/Models/Remote/RemoteCommand.swift \
    \
    MarkView/Models/AgentTools/BrowserAgentTools.swift \
    MarkView/Models/Remote/RemoteWorkspaceTools.swift \
    MarkView/Models/Remote/RemoteToolBridge.swift \
    MarkView/Models/Remote/RemoteProviderConfiguration.swift MarkView/Models/AI/Providers/*.swift \
    tools/tests/RemoteWorkspaceModes.swift
    "$out/remote-workspace-tests" "$@"
    ;;
  --core-only) bash tools/tests/remote-workspace-host-tests.sh --core-only ;;
  *) bash tools/tests/remote-workspace-host-tests.sh ;;
esac
if [ "${MARKVIEW_REMOTE_SKIP_DUPLICATE_PURE:-0}" != 1 ]; then
    bash tools/tests/remote-relay-settings-tests.sh
fi
bash tools/tests/remote-relay-tests.sh
