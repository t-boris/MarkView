#!/bin/bash
# Bump the app version everywhere it is defined (project.yml + both build
# configurations in MarkView.xcodeproj). Marketing version and build number stay equal.
#   ./bump-version.sh patch|minor|major
set -euo pipefail
cd "$(dirname "$0")"

part="${1:-}"
current=$(sed -n 's/^    MARKETING_VERSION: "\(.*\)"$/\1/p' project.yml)
IFS=. read -r major minor patch <<< "$current"
case "$part" in
    major) major=$((major + 1)); minor=0; patch=0 ;;
    minor) minor=$((minor + 1)); patch=0 ;;
    patch) patch=$((patch + 1)) ;;
    *) echo "usage: $0 patch|minor|major   (current: $current)" >&2; exit 1 ;;
esac
next="$major.$minor.$patch"

sed -i '' "s/^    MARKETING_VERSION: \".*\"$/    MARKETING_VERSION: \"$next\"/" project.yml
sed -i '' "s/^    CURRENT_PROJECT_VERSION: \".*\"$/    CURRENT_PROJECT_VERSION: \"$next\"/" project.yml
sed -i '' "s/MARKETING_VERSION = [0-9.]*;/MARKETING_VERSION = $next;/; s/CURRENT_PROJECT_VERSION = [0-9.]*;/CURRENT_PROJECT_VERSION = $next;/" \
    MarkView.xcodeproj/project.pbxproj

echo "$current -> $next"
