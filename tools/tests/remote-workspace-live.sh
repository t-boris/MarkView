#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
if [[ $# -lt 3 || $# -gt 4 ]]; then
    echo 'Usage: remote-workspace-live.sh <HTTPS relay URL> <access-key file> <MarkView.app> [claude|codex|both]' >&2
    exit 64
fi
relay=$1
key_file=$2
app=$3/Contents/MacOS/MarkView
selection=${4:-both}
if [[ ! -x "$app" || ! -r "$key_file" ]]; then
    echo 'Provide a built MarkView.app and a readable private relay access-key file.' >&2
    exit 64
fi
case "$selection" in
    claude|codex) providers=("$selection") ;;
    both) providers=(claude codex) ;;
    *) echo 'Choose claude, codex or both.' >&2; exit 64 ;;
esac
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -parse-as-library -module-cache-path "${TMPDIR:-/tmp}/markview-remote-test-modules" -o "$out/remote-provider-live" \
    MarkView/Models/Remote/RemoteProtocol.swift MarkView/Models/Remote/RemoteFraming.swift \
    MarkView/Models/Remote/RemoteChannel.swift MarkView/Models/Remote/RemoteWorkspace.swift \
    MarkView/Models/Remote/RemoteCommand.swift MarkView/Models/PTYWriter.swift \
    MarkView/Models/AgentProcesses.swift MarkView/Models/BrowserAgentTools.swift MarkView/Models/Remote/RemoteWorkspaceTools.swift \
    MarkView/Models/Remote/RemoteToolBridge.swift MarkView/Models/Remote/RemoteToolRequests.swift \
    MarkView/Models/Remote/RemoteProviderConfiguration.swift tools/tests/RemoteProviderLiveChecks.swift
for provider in "${providers[@]}"; do
    executable=$(command -v "$provider")
    "$out/remote-provider-live" "$provider" "$executable" "$app" "$relay" "$key_file"
done
