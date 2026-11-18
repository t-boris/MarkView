#!/bin/sh
# A local provider fixture; it refuses to run outside its isolated remote-workspace home.
set -eu
[ -n "${CFFIXED_USER_HOME:-}" ] || exit 70
test_home=$(cd "$CFFIXED_USER_HOME" && pwd -P)
case "$(pwd -P)/" in
    "$test_home"/Library/Application\ Support/MarkView/RemoteWorkspaces/*/) ;;
    *) echo 'Refusing to run outside the test home' >&2; exit 70 ;;
esac
printf '%s\n' "$$" >> "$test_home/../children.pid"
case " $* " in
    *' app-server '*)
        exec /usr/bin/python3 -u -c '
import json, sys
for line in sys.stdin:
    request = json.loads(line)
    if "id" not in request:
        continue
    result = {"data": []} if request.get("method") == "thread/list" else {}
    print(json.dumps({"id": request["id"], "result": result}), flush=True)
' "$0"
        ;;
esac
printf 'SESSION_STARTED\n'
while IFS= read -r line; do printf '%s\n' "$line"; done
