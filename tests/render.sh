#!/usr/bin/env bash
# Golden tests for lib/render.awk.
#   tests/render.sh <repo> [awk command] [--update]
# Each fixture in tests/fixtures is drawn several ways and compared with
# tests/golden. pid=ALIVE becomes a live pid, pid=DEAD one that has exited.
set -u
REPO=${1:?usage: render.sh <repo> [awk] [--update]}
AWK=${2:-awk}
UPDATE=${3:-}
T=$(mktemp -d "${TMPDIR:-/tmp}/flowrender.XXXXXX")
trap 'rm -rf "$T"' EXIT

ALIVE=$$
DEAD=$(sh -c 'echo $$')
procfs=0
[ -r /proc/self/stat ] && procfs=1

n=0 failed=0
variants='block:-v mode=block -v rows=4 -v width=80
narrow:-v mode=block -v rows=3 -v width=44
line:-v mode=line -v width=80
full:-v mode=full -v rows=50 -v width=100
ascii:-v mode=block -v rows=4 -v width=80 -v ascii=1
color:-v mode=block -v rows=2 -v width=80 -v color=1'

for fx in "$REPO"/tests/fixtures/*.log; do
    name=${fx##*/}
    name=${name%.log}
    sed "s/pid=ALIVE/pid=$ALIVE/; s/pid=DEAD/pid=$DEAD/" "$fx" > "$T/$name.log"
    while IFS= read -r v; do
        tag=${v%%:*}
        opts=${v#*:}
        case $opts in *color=1*) ;; *) opts="$opts -v color=0" ;; esac
        # shellcheck disable=SC2086
        got=$(LC_ALL=C $AWK -v now=1792047075 -v spin=1 -v procfs=$procfs $opts \
            -f "$REPO/skills/unspin/lib/render.awk" "$T/$name.log" 2>&1)
        gold=$REPO/tests/golden/$name.$tag.txt
        n=$((n + 1))
        if [ "$UPDATE" = --update ]; then
            printf '%s\n' "$got" > "$gold"
            echo "ok $n - $name.$tag (updated)"
        elif [ "$got" = "$(cat "$gold" 2>/dev/null)" ]; then
            echo "ok $n - $name.$tag"
        else
            failed=$((failed + 1))
            echo "not ok $n - $name.$tag"
            diff <(cat "$gold" 2>/dev/null) <(printf '%s\n' "$got") | sed 's/^/#   /' | head -n 20
        fi
    done <<< "$variants"
done

# An empty file draws nothing.
n=$((n + 1))
: > "$T/empty.log"
if [ -z "$(LC_ALL=C $AWK -f "$REPO/skills/unspin/lib/render.awk" "$T/empty.log")" ]; then
    echo "ok $n - empty file draws nothing"
else
    failed=$((failed + 1)); echo "not ok $n - empty file draws nothing"
fi

echo "1..$n"
echo "# $((n - failed)) passed, $failed failed ($AWK)"
[ "$failed" -eq 0 ]
