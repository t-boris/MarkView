#!/bin/bash
# Run continuation and permission checks in an isolated app host with a local ACP fixture.
set -euo pipefail
cd "$(dirname "$0")/../.."
exec bash tools/tests/cli-completion-timeout-host-tests.sh --continuation
