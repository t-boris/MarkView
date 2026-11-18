#!/bin/bash
# Keep all five ARM runners busy with balanced, sequential groups of hosted suites.
set -uo pipefail
if [[ $# != 1 ]]; then echo 'usage: run-hosted-lane.sh LANE' >&2; exit 2; fi
case "$1" in
  0) suites=(qa-general-pair ui-studio-web-tests project-ai-choice-tests) ;;
  1) suites=(studio-pair terminal-host-tests) ;;
  2) suites=(workflow-editor-layout-tests web-pair) ;;
  3) suites=(qa-editor-pair-23 qa-isolated) ;;
  4) suites=(qa-editor-pair-01 welcome-screen-tests studio-network) ;;
  *) echo "Unknown hosted lane: $1" >&2; exit 2 ;;
esac
run_suite() {
    case "$1" in
      qa-general-pair) tools/ci/run-hosted-pair.sh qa-general-0 qa-general-1 ;;
      qa-editor-pair-01) tools/ci/run-hosted-pair.sh qa-editor-0 qa-editor-1 ;;
      qa-editor-pair-23) tools/ci/run-hosted-pair.sh qa-editor-2 qa-editor-3 ;;
      web-pair) tools/ci/run-hosted-pair.sh theme-web-tests research-map-web-tests ;;
      studio-pair) tools/ci/run-hosted-pair.sh studio-session studio-recovery ;;
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
