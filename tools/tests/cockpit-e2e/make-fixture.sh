#!/bin/bash
# Builds the project the Cockpit end-to-end checks run in: a tiny git repository with one source file, committed and clean.
#
#   make-fixture.sh <folder>
#
# The folder is removed first. Nothing here touches a real project.
set -e
DIR=$1
[ -n "$DIR" ] || { echo "usage: $0 <folder>"; exit 2; }
rm -rf "$DIR"
mkdir -p "$DIR/src" "$DIR/docs"
cd "$DIR"
git init -q -b main
git config user.email "e2e@example.invalid"
git config user.name "Cockpit E2E"
cat > src/app.py <<'EOF'
def greet(name):
    return "Hello, " + name
EOF
cat > README.md <<'EOF'
# Cockpit E2E fixture

A throwaway project for the Cockpit enforcement checks.
EOF
printf '.dde/\n' > .gitignore
git add -A
git commit -q -m "Initial fixture"
echo "fixture ready: $DIR"
