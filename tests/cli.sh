#!/usr/bin/env bash
# Tests for bin/unspin and lib/setup.sh, in a throwaway HOME.
#   tests/cli.sh <repo>
set -u
REPO=$(cd "${1:?usage: cli.sh <repo>}" && pwd -P)
FL=$REPO/skills/unspin/bin/unspin
T=$(mktemp -d "${TMPDIR:-/tmp}/flowcli.XXXXXX")
trap 'rm -rf "$T"' EXIT
export UNSPIN_DIR=$T/flow HOME=$T/home
unset UNSPIN_FILE UNSPIN_STEP UNSPIN_SESSION CLAUDE_CODE_SESSION_ID XDG_STATE_HOME CLAUDE_CONFIG_DIR
mkdir -p "$UNSPIN_DIR" "$HOME/.claude"

pass=0 failed=0 n=0
check() {
    local name=$1
    shift
    n=$((n + 1))
    if eval "$*"; then pass=$((pass + 1)); echo "ok $n - $name"
    else failed=$((failed + 1)); echo "not ok $n - $name"; printf '#   %s\n' "$*"; fi
}
strip() { sed $'s/\033\\[[0-9;]*m//g'; }

printf '@1792047000 Build\n▶ @1792047001 id=1.1 pid=%s compiling\n%% @1792047002 id=1.1 3/10 a.c\n' $$ > "$UNSPIN_DIR/s1.log"

out=$(echo '{"session_id":"s1"}' | UNSPIN_WIDTH=60 "$FL" statusline -- sh -c 'cat > /dev/null; printf "BASE LINE"' | strip)
check "statusline: base first, then the block" '[ "$(printf "%s\n" "$out" | head -n 1)" = "BASE LINE" ] && printf "%s\n" "$out" | sed -n 2p | grep -q "^▶ Build"'
check "statusline: block has a fixed height" '[ "$(printf "%s\n" "$out" | wc -l | tr -d " ")" = 6 ]'

out=$(echo '{"session_id":"none"}' | "$FL" statusline -- sh -c 'cat > /dev/null; printf "BASE"')
check "statusline: no flow, only the base" '[ "$out" = BASE ]'

out=$(echo '{"session_id":"none"}' | "$FL" statusline)
check "statusline: no flow, no base, nothing" '[ -z "$out" ]'

out=$(echo '{"session_id":"s1"}' | "$FL" statusline -- sh -c 'exit 3')
check "statusline: a failing base still shows the flow" 'printf "%s\n" "$out" | grep -q "Build"'

out=$(echo '{"session_id":"s1"}' | UNSPIN_WIDTH=80 "$FL" statusline --line | strip)
check "statusline --line: one line" '[ "$(printf "%s\n" "$out" | wc -l | tr -d " ")" = 1 ] && case $out in *compiling*3/10*) true ;; *) false ;; esac'

out=$(echo '{"session_id":"s1"}' | NO_COLOR=1 "$FL" statusline)
check "NO_COLOR turns colour off" '! printf "%s" "$out" | grep -q $'"'"'\033'"'"''

check "block prints the flow for a session" '[ -n "$("$FL" block s1)" ] && [ -z "$("$FL" block nope)" ]'

check "show prints every step" '"$FL" show s1 | grep -q compiling'

out=$(cd "$T" && UNSPIN_SESSION=emit "$FL" title "From Python" 2 && UNSPIN_SESSION=emit "$FL" step "convert" && UNSPIN_SESSION=emit "$FL" progress 3 9 x.png && UNSPIN_SESSION=emit "$FL" ok "done"; cat "$UNSPIN_DIR/emit.log")
check "emitters write the protocol" 'printf "%s\n" "$out" | grep -q "^@.* From Python \[2\]" && printf "%s\n" "$out" | grep -q "^▶ @.* pid=[0-9]* convert" && printf "%s\n" "$out" | grep -q "^% @.* 3/9 x.png" && printf "%s\n" "$out" | grep -q "^✔ @.* done"'

check "path points at unspin.sh" '[ -f "$("$FL" path)" ]'
check "version" '"$FL" version | grep -q "^unspin [0-9]"'
check "unknown command fails" '! "$FL" frobnicate 2>/dev/null'

# ---------------------------------------------------------------- setup
S=$HOME/.claude/settings.json
if command -v python3 > /dev/null; then
    cat > "$S" << 'EOF'
{
  "hooks": {
    "PreToolUse": [
      {"matcher": "Agent", "hooks": [{"type": "command", "command": "guard.sh"}]},
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "bash ~/.claude/skills/unspin/hooks/pretool-nudge.sh", "timeout": 5}]}
    ]
  },
  "statusLine": {"type": "command", "command": "cat > /dev/null; printf 'BASE %s' \"my arg\"", "padding": 1},
  "theme": "dark"
}
EOF
    cp "$S" "$T/orig.json"
    "$FL" setup > "$T/setup.out" 2>&1
    check "setup succeeds" '[ $? -eq 0 ] || grep -q Done "$T/setup.out"'
    check "setup wraps a status line with shell syntax in sh -c" 'python3 -c "import json,sys; c=json.load(open(sys.argv[1]))[\"statusLine\"][\"command\"]; sys.exit(0 if \"statusline -- sh -c\" in c and \"my arg\" in c else 1)" "$S"'
    check "setup keeps other statusLine keys" 'python3 -c "import json,sys; s=json.load(open(sys.argv[1]))[\"statusLine\"]; sys.exit(0 if s[\"padding\"]==1 and s[\"refreshInterval\"]==1 else 1)" "$S"'
    check "setup replaces the old flow hook in place" 'python3 -c "
import json,sys
h=json.load(open(sys.argv[1]))[\"hooks\"]
pre=[x[\"command\"] for e in h[\"PreToolUse\"] for x in e[\"hooks\"]]
ups=[x[\"command\"] for e in h[\"UserPromptSubmit\"] for x in e[\"hooks\"]]
sys.exit(0 if pre[0]==\"guard.sh\" and pre[1].endswith(\"hooks/nudge.sh\") and len(pre)==2 and len(ups)==1 else 1)" "$S"'
    check "setup links the skill and the command" '[ -L "$HOME/.claude/skills/unspin" ] && [ -L "$HOME/.local/bin/unspin" ]'

    python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['statusLine']['command'])" "$S" > "$T/wrapped"
    # shellcheck disable=SC2034 # read by check
    out=$(echo '{"session_id":"s1"}' | sh -c "$(cat "$T/wrapped")" 2>&1 | head -n 1)
    check "the wrapped command runs the original, quoting intact" '[ "$out" = "BASE my arg" ]'

    cp "$S" "$T/after1.json"
    "$FL" setup > /dev/null 2>&1
    check "setup is idempotent" 'cmp -s "$S" "$T/after1.json"'

    mkdir -p "$HOME/.agents/skills"
    "$FL" setup > /dev/null 2>&1
    check "setup links ~/.agents/skills when it exists" '[ -L "$HOME/.agents/skills/unspin" ]'

    "$FL" doctor > "$T/doctor.out" 2>&1
    check "doctor is happy after setup" 'grep -q "0 to fix" "$T/doctor.out"'

    "$FL" uninstall > /dev/null 2>&1
    check "uninstall restores the status line" 'python3 -c "import json,sys; a=json.load(open(sys.argv[1]))[\"statusLine\"]; b=json.load(open(sys.argv[2]))[\"statusLine\"]; sys.exit(0 if a==b else 1)" "$T/orig.json" "$S"'
    check "uninstall removes the hooks it owns, keeps the rest" 'python3 -c "
import json,sys
h=json.load(open(sys.argv[1]))[\"hooks\"]
pre=[x[\"command\"] for e in h[\"PreToolUse\"] for x in e[\"hooks\"]]
sys.exit(0 if pre==[\"guard.sh\"] and \"UserPromptSubmit\" not in h else 1)" "$S"'
    check "uninstall removes the links" '[ ! -e "$HOME/.claude/skills/unspin" ] && [ ! -e "$HOME/.local/bin/unspin" ] && [ ! -e "$HOME/.agents/skills/unspin" ]'

    rm -f "$S"
    "$FL" setup > /dev/null 2>&1
    check "setup without a settings file creates one" 'python3 -c "import json,sys; s=json.load(open(sys.argv[1])); sys.exit(0 if s[\"statusLine\"][\"command\"].endswith(\"unspin statusline\") else 1)" "$S"'
    "$FL" uninstall > /dev/null 2>&1
    check "and uninstall takes it out again" 'python3 -c "import json,sys; s=json.load(open(sys.argv[1])); sys.exit(0 if \"statusLine\" not in s and \"hooks\" not in s else 1)" "$S"'

    echo '{ not json' > "$S"
    check "setup refuses a broken settings file" '! "$FL" setup > /dev/null 2>&1 && [ "$(cat "$S")" = "{ not json" ]'
else
    echo "# python3 not found, setup tests skipped"
fi

# The installer, with a fake curl that serves this tree as release v9.9.9.
mkdir -p "$T/fakebin" "$T/rel/unspin-9.9.9/skills"
cp -R "$REPO/skills/unspin" "$T/rel/unspin-9.9.9/skills/"
tar -czf "$T/rel.tgz" -C "$T/rel" unspin-9.9.9
printf '%s\n' '#!/bin/sh' 'for a; do u=$a; done' 'case $u in' \
    '    *releases/latest) [ -n "${FAKE_RELEASE:-}" ] || exit 22; echo "{\"tag_name\": \"$FAKE_RELEASE\"}" ;;' \
    "    *codeload*) cat '$T/rel.tgz' ;;" \
    '    *) exit 22 ;;' 'esac' > "$T/fakebin/curl"
chmod +x "$T/fakebin/curl"
# shellcheck disable=SC2034 # read by check
out=$(cd "$T" && UNSPIN_HOME=$T/inst1 bash "$REPO/install.sh" --no-setup 2>&1)
check "install.sh run from a clone installs that clone" 'printf "%s" "$out" | grep -q "Installing unspin from $REPO" && [ -x "$T/inst1/bin/unspin" ]'
# shellcheck disable=SC2034 # read by check
out=$(cd "$REPO" && PATH="$T/fakebin:$PATH" FAKE_RELEASE=v9.9.9 UNSPIN_HOME=$T/inst2 bash -s -- --no-setup < "$REPO/install.sh" 2>&1)
check "install.sh piped into bash downloads, even inside a clone" 'printf "%s" "$out" | grep -q "Downloading unspin v9.9.9" && [ -f "$T/inst2/unspin.sh" ]'
# shellcheck disable=SC2034 # read by check
out=$(cd "$T" && PATH="$T/fakebin:$PATH" UNSPIN_HOME=$T/inst3 bash -s -- --no-setup < "$REPO/install.sh" 2>&1)
check "install.sh falls back to main when there is no release" 'printf "%s" "$out" | grep -q "Downloading unspin main" && [ -f "$T/inst3/unspin.sh" ]'

echo "1..$n"
echo "# $pass passed, $failed failed (cli)"
[ "$failed" -eq 0 ]
