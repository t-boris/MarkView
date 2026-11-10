#!/bin/bash
# Runs a Debug build of MarkView invisibly with a probe injected, and prints the probe's log.
#
#   tools/tests/app-probe/run.sh <name> <script-file>
#
# Needs a COPY of the Debug app with its own bundle id (so its preferences are its own), see README.md:
#   PROBE_APP   path to that copy                       (default: $PROBE_WORK/MarkViewProbe.app)
#   PROBE_WORK  scratch folder for homes and outputs    (default: /tmp/markview-probe)
# The app runs with an empty HOME, its own control-socket folder, every window transparent and click-through, and an
# accessory activation policy: nothing appears on the screen and nothing takes the keyboard focus.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REAL_HOME="$HOME"
WORK="${PROBE_WORK:-/tmp/markview-probe}"
APP="${PROBE_APP:-$WORK/MarkViewProbe.app}"
NAME=$1; SCRIPT=$2
[ -n "$NAME" ] && [ -f "$SCRIPT" ] || { echo "usage: $0 <name> <script-file>"; exit 2; }
mkdir -p "$WORK"
[ -f "$WORK/mvprobe.dylib" ] && [ "$WORK/mvprobe.dylib" -nt "$HERE/mvprobe.m" ] || \
    clang -dynamiclib -fobjc-arc -arch arm64 -framework AppKit -framework QuartzCore -o "$WORK/mvprobe.dylib" "$HERE/mvprobe.m"
H="$WORK/home-$NAME"; OUT="$WORK/out-$NAME"; SOCK="$WORK/sock-$NAME"
SECONDS_LIMIT="${PROBE_SECONDS:-90}"
rm -rf "$H" "$OUT"; mkdir -p "$H/Library" "$OUT" "$SOCK"
# PROBE_AI=1 lets the AI command line sign in from the probe's empty home: it needs the login file, its folder, the keychain folder and ~/.local (where `claude` is installed).
# The probe then shares the Keychain with the installed app, so use it only on checks that read no saved password of yours.
if [ -n "$PROBE_AI" ]; then
    ln -s "$REAL_HOME/.claude.json" "$H/.claude.json"; ln -s "$REAL_HOME/.claude" "$H/.claude"; ln -s "$REAL_HOME/Library/Keychains" "$H/Library/Keychains"
    [ -d "$REAL_HOME/.local" ] && ln -s "$REAL_HOME/.local" "$H/.local"
fi
env HOME="$H" CFFIXED_USER_HOME="$H" MARKVIEW_SOCKET_DIR="$SOCK" DYLD_INSERT_LIBRARIES="$WORK/mvprobe.dylib" \
    MV_PROBE_SCRIPT="$SCRIPT" MV_PROBE_OUT="$OUT" MV_PROBE_SECONDS="$SECONDS_LIMIT" \
    "$APP/Contents/MacOS/MarkView" -ApplePersistenceIgnoreState YES > "$OUT/stdout.txt" 2>&1 &
PID=$!
for _ in $(seq 1 $((SECONDS_LIMIT + 10))); do kill -0 $PID 2>/dev/null || break; sleep 1; done
kill -0 $PID 2>/dev/null && kill $PID
cat "$OUT/log.txt"
# Children of the probe (an agent started by a tile) must not outlive it.
sleep 1
ps eww -A -o pid=,command= 2>/dev/null | grep -F "CFFIXED_USER_HOME=$H" | awk '{print $1}' | xargs -I{} kill {} 2>/dev/null || true
