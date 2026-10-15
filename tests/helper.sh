# Tests for unspin.sh. Run by tests/run.sh under each shell:
#   <shell> tests/helper.sh <repo>
# Every case runs in its own subshell with its own flow file.
# shellcheck shell=bash disable=SC2016,SC2030,SC2031

REPO=$(cd "${1:?usage: helper.sh <repo>}" && pwd -P)
FLOW_SH=$REPO/skills/unspin/unspin.sh
T=$(mktemp -d "${TMPDIR:-/tmp}/flowtest.XXXXXX")
trap 'rm -rf "$T"' EXIT
unset UNSPIN_FILE UNSPIN_STEP UNSPIN_SESSION CLAUDE_CODE_SESSION_ID
export UNSPIN_DIR=$T/dir

pass=0 failed=0 n=0
ok_() { n=$((n + 1)); pass=$((pass + 1)); echo "ok $n - $1"; }
nok_() { n=$((n + 1)); failed=$((failed + 1)); echo "not ok $n - $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/#   /'; }

# The flow file with times, ids and pids replaced by fixed tokens.
norm() { sed -E 's/@[0-9]+(\.[0-9]+)?/@T/; s/ id=[0-9]+\.[0-9]+/ id=I/; s/ pid=[0-9]+/ pid=P/; s/ ns=[0-9]+//' "$1"; }

# expect NAME SCRIPT EXPECTED: run SCRIPT in a fresh shell, compare its
# normalised flow file with EXPECTED.
expect() {
    local name=$1 script=$2 want=$3 got
    rm -rf "$UNSPIN_DIR"
    # shellcheck source=/dev/null
    ( UNSPIN_SESSION=t; export UNSPIN_SESSION; . "$FLOW_SH"; eval "$script" ) > "$T/out" 2>&1
    got=$(norm "$UNSPIN_DIR/t.log" 2>/dev/null)
    if [ "$got" = "$want" ]; then ok_ "$name"; else nok_ "$name" "$(printf -- '--- want\n%s\n--- got\n%s\n--- output\n%s' "$want" "$got" "$(cat "$T/out")")"; fi
}

# check NAME CONDITION...: a plain assertion.
check() {
    local name=$1
    shift
    if eval "$*"; then ok_ "$name"; else nok_ "$name" "$*"; fi
}

expect "title with total" 'flow "Build" 3' '@T Build [3]'

expect "step and ok" 'flow X; step "one"; ok "fine"' '@T X
▶ @T id=I pid=P one
✔ @T id=I fine'

expect "step closes the open one" 'flow X; step a; step b; fail "no"' '@T X
▶ @T id=I pid=P a
✔ @T id=I
▶ @T id=I pid=P b
✘ @T id=I no'

expect "ok with nothing open records a step" 'flow X; ok "found it"' '@T X
▶ @T id=I pid=P found it
✔ @T id=I'

expect "run closes by exit status" 'flow X; run "yes" true; run "no" false; echo "rc=$?"' '@T X
▶ @T id=I pid=P yes
✔ @T id=I
▶ @T id=I pid=P no
✘ @T id=I exit 1'

expect "note and multi-line text" 'flow X; note "a
b	c"' '@T X
· @T a b c'

expect "exit closes the open step" 'flow X; step "left open"' '@T X
▶ @T id=I pid=P left open
✔ @T id=I'

expect "failing exit closes it as failed" 'flow X; step "dies"; exit 3' '@T X
▶ @T id=I pid=P dies
✘ @T id=I exit 3'

expect "set -e: failing run stops the script" 'set -e; flow X; run "boom" false; step "never"' '@T X
▶ @T id=I pid=P boom
✘ @T id=I exit 1'

expect "set -eu: quiet happy path" 'set -eu; flow X; step a; progress 1 2; note n; ok; run r true; flow_each e 1 2 -- true; flow_wait w -- true' '@T X
▶ @T id=I pid=P a
% @T id=I 1/2
· @T n
✔ @T id=I
▶ @T id=I pid=P r
✔ @T id=I
▶ @T id=I pid=P e
% @T id=I 0/2 1
% @T id=I 2/2
✔ @T id=I
▶ @T id=I pid=P w
✔ @T id=I first try'

expect "progress keeps the last value" 'flow X; step s; i=0; while [ $i -lt 500 ]; do i=$((i+1)); progress $i 1000 "item $i"; done; ok' '@T X
▶ @T id=I pid=P s
% @T id=I 1/1000 item 1
% @T id=I 500/1000 item 500
✔ @T id=I'

check "progress is throttled" '( UNSPIN_SESSION=thr; . "$FLOW_SH"; flow X; step s; i=0; while [ $i -lt 3000 ]; do i=$((i+1)); progress $i 3000; done; ok ); [ "$(grep -c "^%" "$UNSPIN_DIR/thr.log")" -lt 40 ]'

expect "flow_lines counts lines" 'flow X; step s; printf "a\nb\nc\n" | flow_lines 3 lbl > /dev/null; ok' '@T X
▶ @T id=I pid=P s
% @T id=I 3/3 lbl
✔ @T id=I'

check "flow_lines passes output through untouched" '[ "$( ( . "$FLOW_SH"; printf "a\n\tb \nc" | flow_lines ) )" = "$(printf "a\n\tb \nc")" ]'

expect "flow_lines -p reads counts" 'flow X; step s; printf "[1/4] a\n[3/4] b\nno count\n" | flow_lines -p > /dev/null; ok' '@T X
▶ @T id=I pid=P s
% @T id=I 3/4 no count
✔ @T id=I'

expect "flow_each, sequential, with failures" 'flow X; flow_each "each" a b c -- sh -c "test \"\$1\" != b" _ 2>/dev/null; echo "rc=$?"' '@T X
▶ @T id=I pid=P each
% @T id=I 0/3 a
% @T id=I 3/3 1 failed
✘ @T id=I 1 of 3 failed'

check "flow_each substitutes {} literally" '[ "$( ( . "$FLOW_SH"; flow_each e "a&b c\\1" -- printf "<%s>" "x{}y{}" ) )" = "<xa&b c\\1ya&b c\\1>" ]'

check "flow_each appends the item without {}" '[ "$( ( . "$FLOW_SH"; flow_each e "one two" -- printf "[%s]" ) )" = "[one two]" ]'

check "flow_each reads items from stdin" '[ "$( ( . "$FLOW_SH"; printf "x\ny\n" | flow_each e -- printf "%s," ) )" = "x,y," ]'

check "flow_each -j runs everything and keeps outputs whole" '
out=$( ( . "$FLOW_SH"; flow_each -j 4 e 1 2 3 4 5 6 7 8 9 10 -- sh -c "echo begin \$1; sleep 0.0\$1; echo end \$1" _ ) )
[ "$(printf "%s\n" "$out" | grep -c begin)" = 10 ] && [ "$(printf "%s\n" "$out" | grep -c end)" = 10 ] &&
[ -z "$(printf "%s\n" "$out" | awk "/^begin/ { if (open) bad = 1; open = \$2 } /^end/ { if (\$2 != open) bad = 1; open = \"\" } END { if (bad) print \"interleaved\" }")" ]'

check "flow_each -j reports failures" '( . "$FLOW_SH"; flow_each -j 3 e 1 2 3 4 5 -- sh -c "test \$1 != 3" _ 2>/dev/null ); [ $? -eq 1 ]'

expect "flow_wait times out" 'flow X; flow_wait -t 1 -i 1 "server" -- false; echo "rc=$?"' '@T X
▶ @T id=I pid=P server
% @T id=I 0s/1s try 1
✘ @T id=I timed out after 1s, 2 tries'

check "run -q: quiet on success, tail on failure" '
a=$( ( . "$FLOW_SH"; run -q ok sh -c "echo hidden" ) ); b=$( ( . "$FLOW_SH"; run -q bad sh -c "echo shown; exit 4" ); echo "rc=$?" )
case $a in *hidden*) false ;; *"ok, 1 lines"*) true ;; *) false ;; esac && case $b in *shown*"exit 4"*rc=4*) true ;; *) false ;; esac'

expect "run -l shows the latest line" 'flow X; run -l "live" sh -c "echo one; echo two" > /dev/null' '@T X
▶ @T id=I pid=P live
% @T id=I - two
✔ @T id=I'

check "run -l keeps the exit status" '( . "$FLOW_SH"; run -l x sh -c "exit 7" > /dev/null ); [ $? -eq 7 ]'

check "parallel runs get their own rows" '
( UNSPIN_SESSION=par; . "$FLOW_SH"; flow X; run a sleep 0.2 & run b sleep 0.1 & wait )
f=$UNSPIN_DIR/par.log
[ "$(grep -c "^▶" "$f")" = 2 ] && [ "$(grep -c "^✔" "$f")" = 2 ] &&
[ "$(grep "^▶" "$f" | sed -E "s/.* pid=([0-9]+).*/\1/" | sort -u | wc -l | tr -d " ")" = 2 ]'

check "a step in a subshell leaves the parent open" '
( UNSPIN_SESSION=sub; . "$FLOW_SH"; flow X; step outer; ( step inner; ok ); progress 1 2; ok )
f=$UNSPIN_DIR/sub.log
outer=$(grep "^▶.* outer$" "$f" | sed -E "s/.* id=([0-9.]+).*/\1/")
[ -n "$outer" ] && grep -q "^% .* id=$outer 1/2" "$f" && [ "$(grep -c "^✔.* id=$outer\$" "$f")" = 1 ]'

check "nested script reports into the parent flow" '
( UNSPIN_SESSION=nest; . "$FLOW_SH"; flow Outer; step s; ( unset _FLOW_LOADED; . "$FLOW_SH"; flow Inner; progress 5 10 ); ok )
f=$UNSPIN_DIR/nest.log
head -n 1 "$f" | grep -q Outer && grep -q "^· .*Inner" "$f" && grep -q "^% .* 5/10" "$f"'

check "aliases do not break the helper" '
out=$( ( shopt -s expand_aliases 2>/dev/null; alias ok="echo hijacked"; alias run="echo hijacked"; alias step="echo hijacked"
  UNSPIN_SESSION=al; . "$FLOW_SH"; flow X; run r true; step s; ok ) 2>&1 )
[ -z "$out" ] && [ "$(grep -c "^✔" "$UNSPIN_DIR/al.log")" = 2 ]'

check "unwritable flow dir stays silent" '
out=$( ( UNSPIN_DIR=/proc/nope; export UNSPIN_DIR; . "$FLOW_SH"; flow X; step s; progress 1 2; ok; echo done ) 2>&1 ); [ "$out" = done ]'

check "re-sourcing keeps the open step" '
( UNSPIN_SESSION=re; . "$FLOW_SH"; flow X; step s; . "$FLOW_SH"; ok "closed" ); [ "$(grep -c "^✔.*closed" "$UNSPIN_DIR/re.log")" = 1 ]'

check "UNSPIN_FILE and UNSPIN_STEP are exported" '
out=$( ( UNSPIN_SESSION=env; . "$FLOW_SH"; flow X; step s; sh -c "echo \$UNSPIN_FILE \$UNSPIN_STEP" ) ); case $out in *env.log\ [0-9]*.[0-9]*) true ;; *) false ;; esac'

check "echo mode prints steps to stderr" '
err=$( ( UNSPIN_ECHO=1; export UNSPIN_ECHO; . "$FLOW_SH"; flow T; step "one"; ok; run two false; note n ) 2>&1 >/dev/null )
case $err in *"[unspin] T"*"▶ one"*"✔ one ("*"✘ two — exit 1 ("*"· n"*) true ;; *) false ;; esac'

check "echo turns on by itself under Codex, not under Claude Code" '
a=$( ( unset UNSPIN_ECHO; CODEX_THREAD_ID=x; export CODEX_THREAD_ID; . "$FLOW_SH"; step s ) 2>&1 )
b=$( ( unset UNSPIN_ECHO; CODEX_THREAD_ID=x CLAUDE_CODE_SESSION_ID=y; export CODEX_THREAD_ID CLAUDE_CODE_SESSION_ID; . "$FLOW_SH"; step s ) 2>&1 )
[ -n "$a" ] && [ -z "$b" ]'

check "session id comes from the agent" '
( unset UNSPIN_FILE; COPILOT_AGENT_SESSION_ID=cop-1; export COPILOT_AGENT_SESSION_ID; . "$FLOW_SH"; flow T ); [ -s "$UNSPIN_DIR/cop-1.log" ]'

echo "1..$n"
echo "# $pass passed, $failed failed (${BASH_VERSION:+bash $BASH_VERSION}${ZSH_VERSION:+zsh $ZSH_VERSION})"
[ "$failed" -eq 0 ]
