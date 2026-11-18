#!/bin/bash
# Run independent prebuilt hosted suites concurrently, retaining both results and logs.
set -uo pipefail
if [[ $# != 2 || "$1" == "$2" ]]; then
    echo 'usage: run-hosted-pair.sh FIRST SECOND (different hosted suites)' >&2
    exit 2
fi
run_suite() {
    case "$1" in
        qa-editor-[0-3]|qa-general-[01]) MARKVIEW_QA_HOST_PART="${1#qa-}" ./tools/tests/run.sh qa-web-fault-tests ;;
        studio-session|studio-recovery) MARKVIEW_STUDIO_TEST_PART="${1#studio-}" ./tools/tests/run.sh ui-studio-session-tests ;;
        theme-web-tests|research-map-web-tests) ./tools/tests/run.sh "$1" ;;
        *) echo "Unsupported hosted suite: $1" >&2; return 2 ;;
    esac
}
logs=$(mktemp -d "${TMPDIR:-/tmp}/mv-hosted-pair.XXXXXX") || exit 1
trap 'rm -rf "$logs"' EXIT
run_suite "$1" >"$logs/first" 2>&1 & first=$!
run_suite "$2" >"$logs/second" 2>&1 & second=$!
status=0
wait "$first" || status=1
wait "$second" || status=1
printf '\n--- %s ---\n' "$1"
cat "$logs/first"
printf '\n--- %s ---\n' "$2"
cat "$logs/second"
exit "$status"
