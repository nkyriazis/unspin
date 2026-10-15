#!/bin/bash
# UserPromptSubmit hook: put the finished flow away once the user moves on,
# so the status line shrinks back. A flow with a step still running (say a
# background job) stays. Must print nothing: this event's stdout is added
# to Claude's context.

input=$(cat)
re='"session_id"[[:space:]]*:[[:space:]]*"([^"]*)"'
[[ $input =~ $re ]] || exit 0
sid=${BASH_REMATCH[1]//[^A-Za-z0-9._-]/_}

if [ -n "${UNSPIN_DIR:-}" ]; then dir=$UNSPIN_DIR
elif [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "$XDG_RUNTIME_DIR" ]; then dir=$XDG_RUNTIME_DIR/unspin
else dir=/tmp/unspin-${UID:-$(id -u)}
fi
file=$dir/$sid.log
[ -f "$file" ] || exit 0

# Running means a step with no close whose shell is still alive; the
# renderer already knows how to tell, so ask it for one plain line.
procfs=0
[ -r /proc/self/stat ] && procfs=1
state=$(LC_ALL=C awk -v mode=line -v color=0 -v procfs="$procfs" \
    -f "${BASH_SOURCE[0]%/*}/../lib/render.awk" "$file" 2>/dev/null)
case $state in "▶"*) exit 0 ;; esac
mv -f "$file" "$file.prev" 2>/dev/null

# Once a day, clear out what old sessions left behind.
stamp=$dir/.swept
if [ -z "$(find "$stamp" -mtime -1 2>/dev/null)" ]; then
    touch "$stamp" 2>/dev/null
    find "$dir" -type f ! -name .swept -mtime +2 -delete 2>/dev/null
fi
exit 0
