#!/bin/bash
# Relay Node integration; credential and workspace checks run in isolated app hosts.
set -euo pipefail
cd "$(dirname "$0")/../.."
node --test tools/remote-relay/*.test.mjs
