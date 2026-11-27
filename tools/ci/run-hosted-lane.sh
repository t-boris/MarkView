#!/bin/bash
# Keep all five ARM runners busy with balanced groups of hosted suites, run one after another. Two app hosts at once share the
# host's preferences (`UserDefaults.standard`, kept by cfprefsd whatever the host's home) and the runner's CPU: one suite's
# settings or load changed another's results (PR #476 and #477), so no suites run side by side (Boris, 2026-11-27).
set -uo pipefail
if [[ $# != 1 ]]; then echo 'usage: run-hosted-lane.sh LANE' >&2; exit 2; fi
case "$1" in
  0) suites=(qa-general-0 qa-general-1 ui-studio-web-tests project-ai-choice-tests) ;;
  1) suites=(studio-session studio-recovery terminal-host-tests) ;;
  2) suites=(workflow-editor-layout-tests theme-web-tests research-map-web-tests) ;;
  3) suites=(qa-editor-2 qa-editor-3 qa-isolated) ;;
  4) suites=(qa-editor-0 qa-editor-1 welcome-screen-tests studio-network) ;;
  *) echo "Unknown hosted lane: $1" >&2; exit 2 ;;
esac
run_suite() {
    case "$1" in
      qa-general-[01]|qa-editor-[0-3]) MARKVIEW_QA_HOST_PART="${1#qa-}" ./tools/tests/run.sh qa-web-fault-tests ;;
      studio-session|studio-recovery) MARKVIEW_STUDIO_TEST_PART="${1#studio-}" ./tools/tests/run.sh ui-studio-session-tests ;;
      qa-isolated) MARKVIEW_QA_HOST_PART=isolated ./tools/tests/run.sh qa-web-fault-tests ;;
      studio-network) MARKVIEW_STUDIO_TEST_PART=network ./tools/tests/run.sh ui-studio-session-tests ;;
      *) ./tools/tests/run.sh "$1" ;;
    esac
}
status=0
for suite in "${suites[@]}"; do
    printf '\n--- Hosted suite: %s ---\n' "$suite"
    run_suite "$suite" || status=1
done
exit "$status"
