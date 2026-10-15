#!/bin/bash
# PreToolUse hook on Bash: a non-blocking reminder when a command looks
# batched (control flow, or several chained steps) but is not instrumented.
# At most one reminder per session every 5 minutes. Never blocks and never
# sets a permission decision. Set UNSPIN_NUDGE=0 to turn it off.

[ "${UNSPIN_NUDGE:-1}" = 0 ] && exit 0
input=$(cat)

# No jq: the two fields are pulled out of the JSON text. The command stays
# JSON-escaped apart from newlines and tabs, which is enough for a heuristic.
re='"session_id"[[:space:]]*:[[:space:]]*"([^"]*)"'
[[ $input =~ $re ]] || exit 0
sid=${BASH_REMATCH[1]}
re='"command"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)"'
[[ $input =~ $re ]] || exit 0
cmd=${BASH_REMATCH[1]}
cmd=${cmd//\\n/$'\n'}
cmd=${cmd//\\t/$'\t'}

# Already instrumented, or writing to the flow file by hand.
case $cmd in *unspin.sh* | *UNSPIN_FILE* | *unspin*) exit 0 ;; esac

batched=0
grep -qE '(^|[;&|({[:space:]])(if|for|while|until|case)[[:space:]]' <<< "$cmd" && batched=1
seps=$(grep -oE '&&|\|\||;|$' <<< "$cmd" | wc -l)
[ "$seps" -ge 4 ] && batched=1
[ "$batched" -eq 1 ] || exit 0

if [ -n "${UNSPIN_DIR:-}" ]; then dir=$UNSPIN_DIR
elif [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "$XDG_RUNTIME_DIR" ]; then dir=$XDG_RUNTIME_DIR/unspin
else dir=/tmp/unspin-${UID:-$(id -u)}
fi
[ -d "$dir" ] || (umask 077 && mkdir -p "$dir") 2>/dev/null || exit 0
stamp=$dir/${sid//[^A-Za-z0-9._-]/_}.nudged
[ -n "$(find "$stamp" -mmin -5 2>/dev/null)" ] && exit 0
touch "$stamp" 2>/dev/null

helper=$(cd "${BASH_SOURCE[0]%/*}/.." 2>/dev/null && pwd -P)/unspin.sh
helper=${helper//\\/\\\\}
helper=${helper//\"/\\\"}
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"%s"}}\n' \
    "unspin: this Bash command looks batched (control flow or several chained steps) but is not instrumented. If it is a multi-step flow, source $helper and mark its steps so the user sees them live (see the unspin skill). If it is not really a flow, ignore this."
