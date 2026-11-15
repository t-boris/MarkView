#!/bin/bash
# Bump the app version in both build configurations of MarkView.xcodeproj.
# Marketing version and build number stay equal.
#   ./bump-version.sh patch|minor|major
set -euo pipefail
cd "$(dirname "$0")"

PBX="MarkView.xcodeproj/project.pbxproj"
part="${1:-}"
current=$(grep -m1 'MARKETING_VERSION = ' "$PBX" | sed -E 's/.*MARKETING_VERSION = ([0-9.]+);.*/\1/')
[ -n "$current" ] || { echo "error: MARKETING_VERSION not found in $PBX" >&2; exit 1; }
IFS=. read -r major minor patch <<< "$current"
case "$part" in
    major) major=$((major + 1)); minor=0; patch=0 ;;
    minor) minor=$((minor + 1)); patch=0 ;;
    patch) patch=$((patch + 1)) ;;
    *) echo "usage: $0 patch|minor|major   (current: $current)" >&2; exit 1 ;;
esac
next="$major.$minor.$patch"

sed -i '' "s/MARKETING_VERSION = [0-9.]*;/MARKETING_VERSION = $next;/; s/CURRENT_PROJECT_VERSION = [0-9.]*;/CURRENT_PROJECT_VERSION = $next;/" \
    "$PBX"

marketing_count=$(grep -c "MARKETING_VERSION = $next;" "$PBX" || true)
build_count=$(grep -c "CURRENT_PROJECT_VERSION = $next;" "$PBX" || true)
if [ "$marketing_count" -lt 2 ] || [ "$build_count" -lt 2 ]; then
    echo "error: version update in $PBX did not match both Debug and Release configurations" >&2
    exit 1
fi

echo "$current -> $next"
