#!/bin/bash
# WebHost in real WebKit: retain checks in both Debug and Release package builds.
set -euo pipefail
cd "$(dirname "$0")/../.."
swift test --package-path Packages/MarkViewCore --filter WebHostIntegrationTests
swift test --package-path Packages/MarkViewCore -c release --filter WebHostIntegrationTests
