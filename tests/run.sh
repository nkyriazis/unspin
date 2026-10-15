#!/usr/bin/env bash
# Run the test suites.
#   tests/run.sh             with the shells and awks installed here
#   tests/run.sh --docker    the full matrix: bash 3.2 to 5.3, zsh, and five awks
# The run is itself a flow, so `unspin watch` (or the Claude Code status
# line) shows it live.
set -u
REPO=$(cd "${BASH_SOURCE[0]%/*}/.." && pwd -P)
# shellcheck source=../skills/unspin/unspin.sh
. "$REPO/skills/unspin/unspin.sh"
LOG=$(mktemp "${TMPDIR:-/tmp}/unspin-tests.XXXXXX")
failed=0

# suite "label" cmd...: run one suite, count its results as they arrive.
suite() {
    local label=$1 rc
    shift
    step "$label"
    "$@" 2>&1 | tee -a "$LOG" | flow_lines -p > /dev/null
    rc=$(tail -n 1 "$LOG")
    if grep -q "^# .* 0 failed" <<< "$rc"; then ok "${rc#\# }"; else fail "${rc#\# }"; failed=$((failed + 1)); fi
}

if [ "${1:-}" = --docker ]; then
    command -v docker > /dev/null || { echo "docker not found" >&2; exit 2; }
    image=flowtest:alpine
    flow "Test matrix" 11
    step "building test image"
    docker build -q -t "$image" "$REPO/tests/docker" > /dev/null || { fail; exit 1; }
    ok
    for v in 3.2 4.4 5.2 5.3; do
        suite "helper, bash $v" docker run --rm -v "$REPO:/repo:ro" "bash:$v" bash /repo/tests/helper.sh /repo
    done
    suite "helper, zsh" docker run --rm -v "$REPO:/repo:ro" "$image" zsh /repo/tests/helper.sh /repo
    for a in mawk gawk "busybox awk" bwk-awk bwk-awk-2020; do
        suite "render, $a" docker run --rm -v "$REPO:/repo:ro" "$image" bash /repo/tests/render.sh /repo "$a"
    done
else
    flow "Tests" 4
    suite "helper, bash $BASH_VERSION" bash "$REPO/tests/helper.sh" "$REPO"
    if command -v zsh > /dev/null; then suite "helper, zsh" zsh "$REPO/tests/helper.sh" "$REPO"; fi
    suite "render, $(awk --version 2>/dev/null | head -n 1 | cut -d, -f1 || echo awk)" "$REPO/tests/render.sh" "$REPO" awk
    suite "cli and setup" "$REPO/tests/cli.sh" "$REPO"
fi

grep '^not ok' -A 12 "$LOG" | head -n 80
note "$( [ "$failed" -eq 0 ] && echo "all suites passed" || echo "$failed suite(s) failed" ), log in $LOG"
echo "$( [ "$failed" -eq 0 ] && echo "all suites passed" || echo "$failed suite(s) failed" ) (log: $LOG)"
[ "$failed" -eq 0 ]
