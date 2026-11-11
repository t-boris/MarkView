#!/bin/bash
# Project mood selection and bounded local platform inspection. No app, network or AI calls.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -parse-as-library MarkView/Models/ProjectBackdrop.swift MarkView/Models/WelcomeBackdrop.swift \
    tools/tests/ProjectBackdropChecks.swift -o "$out/project-backdrops"
"$out/project-backdrops"
