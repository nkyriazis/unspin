# unspin.sh: show the steps of a batched shell command live, with progress.
# shellcheck shell=bash disable=SC2034,SC2154
#
# Source it from bash (3.2 or newer) or zsh, then call
#
#   flow "Title" [N]                   start a new flow (N = planned steps)
#   step "msg"                         open a step; this shell's open step closes ✔
#   ok ["detail"]  fail ["detail"]     close the open step
#   note "msg"                         a side note, not a step
#   run [-l|-p|-q] "msg" cmd [args]    step, run cmd, close by its exit status
#   progress N [TOTAL] [label]         update the open step (throttled)
#   cmd | flow_lines [-p] [TOTAL] [label] | ...      output lines as progress
#   flow_each [-j N] "msg" item... -- cmd [args]     one bar over a loop
#   flow_wait [-t SECS] [-i SECS] "msg" -- cmd [args]  retry until cmd succeeds
#
# Jobs started with `run ... &` show as parallel rows. Events are appended to
# $UNSPIN_FILE, which the status line (or `unspin watch`) redraws every second.
# The line format is in docs/protocol.md; anything that can append a line to
# a file can write it.

# The caller's aliases must not rewrite the definitions below.
unalias flow step ok fail note run progress flow_lines flow_each flow_wait 2>/dev/null || :

if [ -n "${ZSH_VERSION:-}" ]; then
    zmodload zsh/datetime 2>/dev/null || :   # EPOCHREALTIME
    zmodload zsh/system 2>/dev/null || :     # sysparams[pid]
fi

UNSPIN_VERSION=1.0.0

# The agent session this shell belongs to, from whichever agent started it.
_flow_sid() {
    _FLOW_SID=${UNSPIN_SESSION:-${CLAUDE_CODE_SESSION_ID:-${COPILOT_AGENT_SESSION_ID:-${CODEX_SESSION_ID:-${CODEX_THREAD_ID:-${CURSOR_CONVERSATION_ID:-${OPENCODE_SESSION_ID:-${AMP_CURRENT_THREAD_ID:-${AGENT_SESSION_ID:-default}}}}}}}}}
}

# Where events go. The renderer resolves the same path from the session id it
# is given, so both sides must agree: UNSPIN_DIR, else $XDG_RUNTIME_DIR/unspin,
# else /tmp/unspin-$UID (not $TMPDIR, which a sandbox may change for one side).
_flow_init() {
    local sid dir
    if [ -n "${UNSPIN_FILE:-}" ]; then
        _FLOW_D=${UNSPIN_FILE%/*}
        [ "$UNSPIN_FILE" != /dev/null ] || _FLOW_D=
        export UNSPIN_FILE
        return 0
    fi
    _flow_sid
    sid=$_FLOW_SID
    case $sid in *[!A-Za-z0-9._-]*) sid=$(printf '%s' "$sid" | tr -c 'A-Za-z0-9._-' _) ;; esac
    if [ -n "${UNSPIN_DIR:-}" ]; then
        dir=$UNSPIN_DIR
    elif [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "${XDG_RUNTIME_DIR:-}" ]; then
        dir=$XDG_RUNTIME_DIR/unspin
    else
        dir=/tmp/unspin-${UID:-$(id -u)}
    fi
    [ -d "$dir" ] || (umask 077 && mkdir -p "$dir") 2>/dev/null || :
    if [ -d "$dir" ] && [ -O "$dir" ] && [ -w "$dir" ]; then
        UNSPIN_FILE=$dir/$sid.log _FLOW_D=$dir
    else
        UNSPIN_FILE=/dev/null _FLOW_D=
    fi
    export UNSPIN_FILE
}

if [ -z "${_FLOW_LOADED:-}" ]; then
    _FLOW_LOADED=1
    _FLOW_ID='' _FLOW_OPENER='' _FLOW_N=0 _FLOW_PEND='' _FLOW_TICKW=-1000000
    # A script started inside another flow's step reports into that flow.
    _FLOW_NESTED=${UNSPIN_STEP:+1}
    _flow_init
    # Pid namespace, so a renderer outside a sandbox can tell it cannot
    # check our pids (Linux only).
    _FLOW_NS=''
    if [ -r /proc/self/ns/pid ]; then
        _FLOW_NS=$(readlink /proc/self/ns/pid 2>/dev/null) || :
        _FLOW_NS=${_FLOW_NS//[!0-9]/}
    fi
    # Agents with no live status line (Codex, Gemini CLI, opencode, Goose,
    # Cline, Cursor...) still show command output as it arrives, so there the
    # steps are also echoed to stderr, briefly. Claude Code and Copilot CLI
    # draw the status line instead. UNSPIN_ECHO=1 or 0 decides it either way.
    if [ -z "${UNSPIN_ECHO:-}" ]; then
        UNSPIN_ECHO=0
        if [ -z "${CLAUDE_CODE_SESSION_ID:-}${COPILOT_AGENT_SESSION_ID:-}" ] &&
            [ -n "${CODEX_SESSION_ID:-}${CODEX_THREAD_ID:-}${CODEX_CI:-}${GEMINI_CLI:-}${OPENCODE:-}${OPENCODE_SESSION_ID:-}${CURSOR_AGENT:-}${CURSOR_CONVERSATION_ID:-}${AMP_CURRENT_THREAD_ID:-}${AGENT_SESSION_ID:-}${CLINE_ACTIVE:-}${GOOSE_TERMINAL:-}" ]; then
            UNSPIN_ECHO=1
        fi
    fi
    _FLOW_MSG='' _FLOW_T0='' _FLOW_EST=0
    if [ -n "${EPOCHREALTIME:-}" ]; then
        _FLOW_CLK=rt
    elif printf -v _FLOW_T '%(%s)T' -1 2>/dev/null; then
        _FLOW_CLK=pf
    else
        case $(date +%3N 2>/dev/null) in
            [0-9][0-9][0-9]) _FLOW_CLK='date3' ;;
            *) _FLOW_CLK='date' ;;
        esac
    fi
fi

# _FLOW_T: wall clock for the file, with milliseconds when the shell has them.
_flow_clock() {
    case $_FLOW_CLK in
        rt)
            local t=${EPOCHREALTIME/,/.}
            local f=${t#*.}000
            _FLOW_T=${t%%.*}.${f:0:3} ;;
        pf) printf -v _FLOW_T '%(%s)T' -1 ;;
        date3) _FLOW_T=$(date +%s.%3N) ;;
        *) _FLOW_T=$(date +%s) ;;
    esac
}

# _FLOW_TICK: a fork-free microsecond counter, only for throttling.
_flow_tick() {
    if [ "$_FLOW_CLK" = rt ]; then
        local t=${EPOCHREALTIME/,/.}
        local f=${t#*.}000000
        _FLOW_TICK=${t%%.*}${f:0:6}
    else
        _FLOW_TICK=$((SECONDS * 1000000))
    fi
}

# _FLOW_ME: pid of the current shell, subshells included ($$ is not).
_flow_me() {
    if [ -n "${BASHPID:-}" ]; then
        _FLOW_ME=$BASHPID
    elif [ -n "${ZSH_VERSION:-}" ] && [ -n "${sysparams[pid]:-}" ]; then
        _FLOW_ME=${sysparams[pid]}
    else
        _FLOW_ME=$(exec sh -c 'echo "$PPID"')
    fi
}

# _FLOW_S: the arguments as one bounded line.
_flow_text() {
    local IFS=' '
    _FLOW_S=$*
    case $_FLOW_S in
        *[$'\n\r\t']*) _FLOW_S=${_FLOW_S//[$'\n\r\t']/ } ;;
    esac
    if [ ${#_FLOW_S} -gt 300 ]; then _FLOW_S=${_FLOW_S:0:300}; fi
}

_flow_emit() {
    # `>>` fails on a missing file under zsh's noclobber, hence the retry.
    { printf '%s\n' "$1" >> "$UNSPIN_FILE"; } 2>/dev/null ||
        { printf '%s\n' "$1" >| "$UNSPIN_FILE"; } 2>/dev/null || :
}

# A private scratch file: in the flow directory, else from mktemp.
_flow_tmp() {
    if [ -n "$_FLOW_D" ]; then
        _FLOW_TMP=$_FLOW_D/${UNSPIN_FILE##*/}
        _FLOW_TMP=${_FLOW_TMP%.log}.$_FLOW_ID.$1
        : >| "$_FLOW_TMP" 2>/dev/null || _FLOW_TMP=$(mktemp "${TMPDIR:-/tmp}/flow.XXXXXX")
    else
        _FLOW_TMP=$(mktemp "${TMPDIR:-/tmp}/flow.XXXXXX")
    fi
}

# UNSPIN_ECHO: one short stderr line per event, progress at most every 10s.
_flow_ms() {
    local s=${1%%.*} f=000
    case $1 in *.*) f=${1#*.}000 ;; esac
    _FLOW_MS=$((s * 1000 + 10#${f:0:3}))
}

_flow_echo_close() {
    local glyph=$1 detail=$2 d=''
    if [ -n "$_FLOW_T0" ]; then
        _flow_ms "$_FLOW_T"
        d=$_FLOW_MS
        _flow_ms "$_FLOW_T0"
        d=$((d - _FLOW_MS))
        if [ "$d" -lt 10000 ]; then d=" ($((d / 1000)).$((d % 1000 / 100))s)"
        elif [ "$d" -lt 60000 ]; then d=" ($((d / 1000))s)"
        else d=" ($((d / 60000))m$(((d / 1000) % 60))s)"
        fi
    fi
    printf '%s %s%s%s\n' "$glyph" "$_FLOW_MSG" "${detail:+ — $detail}" "$d" >&2
}

flow() {
    _flow_text "${1:-}"
    if [ -n "$_FLOW_NESTED" ]; then
        note "$_FLOW_S"
        return 0
    fi
    _flow_clock
    { printf '@%s %s%s\n' "$_FLOW_T" "$_FLOW_S" "${2:+ [$2]}" >| "$UNSPIN_FILE"; } 2>/dev/null || :
    _FLOW_ID='' _FLOW_OPENER='' _FLOW_PEND=''
    unset UNSPIN_STEP
    if [ "$UNSPIN_ECHO" = 1 ]; then printf '[unspin] %s\n' "$_FLOW_S" >&2; fi
}

step() {
    _flow_me
    if [ -n "$_FLOW_ID" ] && [ "$_FLOW_OPENER" = "$_FLOW_ME" ]; then
        _flow_close "✔"
    fi
    # In a subshell the inherited open step belongs to the parent, which
    # keeps running; this step becomes a parallel row of its own.
    _FLOW_N=$((_FLOW_N + 1))
    _FLOW_ID=$_FLOW_ME.$_FLOW_N _FLOW_OPENER=$_FLOW_ME
    _FLOW_PEND='' _FLOW_TICKW=-1000000
    _flow_clock
    _flow_text "$@"
    _flow_emit "▶ @$_FLOW_T id=$_FLOW_ID pid=$_FLOW_ME${_FLOW_NS:+ ns=$_FLOW_NS} $_FLOW_S"
    UNSPIN_STEP=$_FLOW_ID
    export UNSPIN_STEP
    _FLOW_MSG=$_FLOW_S _FLOW_T0=$_FLOW_T _FLOW_EST=$SECONDS
    if [ "$UNSPIN_ECHO" = 1 ]; then printf '▶ %s\n' "$_FLOW_S" >&2; fi
}

_flow_close() {
    local glyph=$1 detail
    shift
    _flow_text "$@"
    detail=$_FLOW_S
    if [ -z "$_FLOW_ID" ]; then
        # Nothing open: record a step that opens and closes at once.
        _flow_me
        _FLOW_N=$((_FLOW_N + 1))
        _flow_clock
        _flow_emit "▶ @$_FLOW_T id=$_FLOW_ME.$_FLOW_N pid=$_FLOW_ME $detail"
        _flow_emit "$glyph @$_FLOW_T id=$_FLOW_ME.$_FLOW_N"
        if [ "$UNSPIN_ECHO" = 1 ]; then printf '%s %s\n' "$glyph" "$detail" >&2; fi
        return 0
    fi
    _flow_flush
    _flow_clock
    _flow_emit "$glyph @$_FLOW_T id=$_FLOW_ID${detail:+ $detail}"
    if [ "$UNSPIN_ECHO" = 1 ]; then _flow_echo_close "$glyph" "$detail"; fi
    _FLOW_ID='' _FLOW_OPENER='' _FLOW_T0=''
    unset UNSPIN_STEP
}

ok() { _flow_close "✔" "$@"; }
fail() { _flow_close "✘" "$@"; }

note() {
    _flow_clock
    _flow_text "$@"
    _flow_emit "· @$_FLOW_T $_FLOW_S"
    if [ "$UNSPIN_ECHO" = 1 ]; then printf '· %s\n' "$_FLOW_S" >&2; fi
}

# Throttled to 4 writes a second; the status line redraws once a second.
# The final value (N = TOTAL) is always written, and a held-back value is
# written when the step closes, so a closed step shows its real count.
progress() {
    local body=${1:--}${2:+/$2}
    if [ -n "${3:-}" ]; then
        _flow_text "$3"
        body="$body $_FLOW_S"
    fi
    _flow_tick
    if [ "${1:-}" != "${2:-}" ] && [ $((_FLOW_TICK - _FLOW_TICKW)) -lt 250000 ]; then
        _FLOW_PEND=$body
        return 0
    fi
    _FLOW_TICKW=$_FLOW_TICK _FLOW_PEND=''
    _flow_clock
    local id=${_FLOW_ID:-${UNSPIN_STEP:-}}
    _flow_emit "% @$_FLOW_T${id:+ id=$id} $body"
    if [ "$UNSPIN_ECHO" = 1 ] && [ $((SECONDS - _FLOW_EST)) -ge 10 ]; then
        _FLOW_EST=$SECONDS
        printf '  %s %s\n' "${_FLOW_MSG:-…}" "$body" >&2
    fi
}

_flow_flush() {
    if [ -n "$_FLOW_PEND" ]; then
        _flow_clock
        local id=${_FLOW_ID:-${UNSPIN_STEP:-}}
        _flow_emit "% @$_FLOW_T${id:+ id=$id} $_FLOW_PEND"
        _FLOW_PEND=''
    fi
}

# Pass stdin through (to stdout, or to OUT) while writing progress events:
# the latest line as the label, plus a count. COUNT is "lines" (count lines,
# against TOTAL when given), "parse" (take N/M or P% from the line itself)
# or "none". At most one event a second, and one at the end.
_flow_live() {
    local count=$1 out=$2 total=$3 label=$4
    _flow_text "$label"
    # Strings go through the environment: awk -v would expand backslashes.
    _FLOW_LIVE_ID=${_FLOW_ID:-${UNSPIN_STEP:-}} _FLOW_LIVE_OUT=$out _FLOW_LIVE_LABEL=$_FLOW_S \
    LC_ALL=C awk -v count="$count" -v total="$total" '
    function clock(   t) { srand(); t = srand(); return t }
    function cut(s, n) {
        # Byte-bounded, but never in the middle of a UTF-8 sequence.
        if (length(s) <= n) return s
        while (n > 0 && (substr(s, n + 1, 1) in cont)) n--
        return substr(s, 1, n)
    }
    function emit(   body) {
        if (count == "lines") body = n (total != "" ? "/" total : "")
        else if (count == "parse" && cnt != "") body = cnt
        else body = "-"
        lab = (label != "") ? label : cur
        if (lab != "") body = body " " cut(lab, 200)
        if (body == last_body) return
        last_body = body
        printf "%% @%d%s %s\n", clock(), (id != "" ? " id=" id : ""), body >> f
        close(f)
    }
    BEGIN {
        f = ENVIRON["UNSPIN_FILE"]; id = ENVIRON["_FLOW_LIVE_ID"]
        out = ENVIRON["_FLOW_LIVE_OUT"]; label = ENVIRON["_FLOW_LIVE_LABEL"]
        for (i = 128; i < 192; i++) cont[sprintf("%c", i)] = 1
        last = clock()
    }
    {
        if (out != "") print > out; else print
        n++
        line = $0
        if (index(line, "\r")) {
            # Progress meters redraw with \r: keep the last non-empty frame.
            k = split(line, seg, "\r"); line = seg[k]
            while (line ~ /^[ \t]*$/ && k > 1) line = seg[--k]
        }
        gsub(/\033\[[0-9;?]*[ -\/]*[@-~]/, "", line)
        gsub(/[\001-\037\177]/, " ", line)
        if (line ~ /[^ ]/) { sub(/^ +/, "", line); cur = line }
        if (count == "parse") {
            if (match(line, /[0-9]+\/[0-9]+/)) {
                c = substr(line, RSTART, RLENGTH); split(c, nm, "/")
                if (nm[2] + 0 > 0 && nm[1] + 0 <= nm[2] + 0) cnt = c
            } else if (match(line, /[0-9]+(\.[0-9]+)?%/)) {
                cnt = substr(line, RSTART, RLENGTH)
            }
        }
        t = clock()
        if (t != last) { last = t; emit(); if (out == "") fflush() }
    }
    END { emit(); if (out != "") close(out) }'
}

run() {
    local mode='' count=none
    while [ $# -gt 0 ]; do
        case $1 in
            -q | --quiet) mode=q ;;
            -l | --live) mode=${mode:-l} ;;
            -p | --parse) count=parse mode=${mode:-l} ;;
            -qp | -pq) mode=q count=parse ;;
            --) shift; break ;;
            *) break ;;
        esac
        shift
    done
    local msg=${1:-} rc=0
    if [ $# -gt 0 ]; then shift; fi
    step "$msg"
    if [ -z "$mode" ]; then
        "$@" || rc=$?
    else
        local rcf out=''
        _flow_tmp rc
        rcf=$_FLOW_TMP
        if [ "$mode" = q ]; then
            _flow_tmp out
            out=$_FLOW_TMP
        fi
        { rc=0; "$@" || rc=$?; echo "$rc" >| "$rcf"; } 2>&1 | _flow_live "$count" "$out" "" ""
        rc=1
        read -r rc < "$rcf" 2>/dev/null || :
        rm -f "$rcf"
        if [ -n "$out" ]; then
            if [ "$rc" -eq 0 ]; then
                echo "[unspin] $msg: ok, $(wc -l < "$out" | tr -d ' ') lines of output in $out"
            else
                tail -n 40 "$out"
                echo "[unspin] $msg: exit $rc, full output in $out"
            fi
        fi
    fi
    if [ "$rc" -eq 0 ]; then ok; else fail "exit $rc"; fi
    return "$rc"
}

flow_lines() {
    local count=lines
    case ${1:-} in -p | --parse) count=parse; shift ;; esac
    _flow_live "$count" "" "${1:-}" "${2:-}"
}

# _FLOW_ARGV: the command with {} replaced by the item, or the item appended
# when there is no {}. Pattern removal, not ${a//x/y}: the replacement side
# of that treats & and quotes differently across bash versions.
_flow_argv() {
    local item=$1 a out used=''
    shift
    _FLOW_ARGV=()
    for a in "$@"; do
        case $a in
            *'{}'*)
                used=1 out=''
                while :; do
                    case $a in
                        *'{}'*) out=$out${a%%'{}'*}$item a=${a#*'{}'} ;;
                        *) break ;;
                    esac
                done
                _FLOW_ARGV+=("$out$a") ;;
            *) _FLOW_ARGV+=("$a") ;;
        esac
    done
    if [ -z "$used" ]; then _FLOW_ARGV+=("$item"); fi
}

flow_each() {
    local jobs=1
    while [ $# -gt 0 ]; do
        case $1 in
            -j) jobs=${2:-1}; shift ;;
            -j*) jobs=${1#-j} ;;
            *) break ;;
        esac
        shift
    done
    case $jobs in '' | *[!0-9]*) jobs=1 ;; esac
    local msg=${1:-}
    if [ $# -gt 0 ]; then shift; fi
    local -a items
    items=()
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do
        items+=("$1")
        shift
    done
    if [ "${1:-}" = "--" ]; then shift; fi
    if [ $# -eq 0 ]; then
        echo "flow_each: usage: flow_each [-j N] \"msg\" item... -- cmd [args]  ({} = item)" >&2
        return 2
    fi
    if [ ${#items[@]} -eq 0 ] && [ ! -t 0 ]; then
        local line
        while IFS= read -r line || [ -n "$line" ]; do items+=("$line"); done
    fi
    local total=${#items[@]} done=0 failed=0 failures='' item rc label
    step "$msg"
    if [ "$total" -eq 0 ]; then
        ok "nothing to do"
        return 0
    fi
    if [ "$jobs" -le 1 ]; then
        for item in "${items[@]}"; do
            label=$item
            if [ "$failed" -gt 0 ]; then label="$label · $failed failed"; fi
            progress "$done" "$total" "$label"
            _flow_argv "$item" "$@"
            rc=0
            "${_FLOW_ARGV[@]}" < /dev/null || rc=$?
            done=$((done + 1))
            if [ "$rc" -ne 0 ]; then
                failed=$((failed + 1))
                failures="$failures  $item (exit $rc)"$'\n'
            fi
        done
    else
        # N workers take every Nth item and report "rc<TAB>index<TAB>item"
        # lines on a FIFO. Each holds it open for its whole life, so the
        # reader sees EOF only when the last worker is gone. Output is
        # buffered per item and printed whole, in completion order.
        local tmp w=0 k idx
        tmp=$(mktemp -d "${TMPDIR:-/tmp}/unspin-each.XXXXXX") || return 1
        mkfifo "$tmp/fifo" || { rm -rf "$tmp"; return 1; }
        while [ "$w" -lt "$jobs" ]; do
            (
                k=0
                for item in "${items[@]}"; do
                    if [ $((k % jobs)) -eq "$w" ]; then
                        _flow_argv "$item" "$@"
                        rc=0
                        "${_FLOW_ARGV[@]}" > "$tmp/$k.out" 2>&1 < /dev/null || rc=$?
                        printf '%s\t%s\t%s\n' "$rc" "$k" "$item"
                    fi
                    k=$((k + 1))
                done
            ) > "$tmp/fifo" &
            w=$((w + 1))
        done
        progress 0 "$total" "$jobs jobs"
        while IFS=$'\t' read -r rc idx item; do
            cat "$tmp/$idx.out" 2>/dev/null
            done=$((done + 1))
            if [ "$rc" -ne 0 ]; then
                failed=$((failed + 1))
                failures="$failures  $item (exit $rc)"$'\n'
            fi
            label=$item
            if [ "$failed" -gt 0 ]; then label="$label · $failed failed"; fi
            progress "$done" "$total" "$label"
        done < "$tmp/fifo"
        wait
        rm -rf "$tmp"
        if [ "$done" -lt "$total" ]; then
            failed=$((failed + total - done))
            failures="$failures  $((total - done)) items never reported (worker killed?)"$'\n'
        fi
    fi
    if [ "$failed" -eq 0 ]; then
        progress "$total" "$total"
        ok
        return 0
    fi
    progress "$done" "$total" "$failed failed"
    printf 'flow_each: %s of %s failed\n%s' "$failed" "$total" "$failures" | head -n 21 >&2
    fail "$failed of $total failed"
    return 1
}

flow_wait() {
    local timeout=60 every=1
    while [ $# -gt 0 ]; do
        case $1 in
            -t) timeout=${2:-60}; shift ;;
            -t*) timeout=${1#-t} ;;
            -i) every=${2:-1}; shift ;;
            -i*) every=${1#-i} ;;
            *) break ;;
        esac
        shift
    done
    local msg=${1:-}
    if [ $# -gt 0 ]; then shift; fi
    if [ "${1:-}" = "--" ]; then shift; fi
    step "$msg"
    local start=$SECONDS tries=0 out rc elapsed
    while :; do
        tries=$((tries + 1))
        rc=0
        out=$("$@" 2>&1 < /dev/null) || rc=$?
        if [ "$rc" -eq 0 ]; then
            if [ -n "$out" ]; then printf '%s\n' "$out"; fi
            if [ "$tries" -eq 1 ]; then ok "first try"; else ok "after $tries tries"; fi
            return 0
        fi
        elapsed=$((SECONDS - start))
        if [ "$elapsed" -ge "$timeout" ]; then
            if [ -n "$out" ]; then printf '%s\n' "$out" | tail -n 20; fi
            fail "timed out after ${timeout}s, $tries tries"
            return 1
        fi
        progress "${elapsed}s" "${timeout}s" "try $tries"
        sleep "$every"
    done
}

# Close a step this shell left open when it exits, so a crashed script never
# looks like it is still running. A step killed outright (SIGKILL) is caught
# by the renderer instead: its pid is gone.
_flow_exit() {
    local rc=$?
    # The trap's status becomes the script's: hand back the script's own.
    if [ -n "$_FLOW_ID" ]; then
        _flow_me
        if [ "$_FLOW_OPENER" = "$_FLOW_ME" ]; then
            if [ "$rc" -eq 0 ]; then _flow_close "✔"; else _flow_close "✘" "exit $rc"; fi
        fi
    fi
    return "$rc"
}
trap _flow_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
