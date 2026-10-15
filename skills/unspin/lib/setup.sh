# setup.sh: wire unspin into Claude Code, check it, and take it out again.
# Sourced by bin/unspin, which sets ROOT, PROG, VERSION and die().
# shellcheck shell=bash

CLAUDE_DIR=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
SETTINGS=$CLAUDE_DIR/settings.json
STATE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/unspin
BIN_DIR=${FLOWLINE_BIN_DIR:-$HOME/.local/bin}

say() { printf '  %s\n' "$*"; }
step_msg() { printf '%s\n' "$*"; }

# Paths under $HOME are written as ~/..., so a synced settings.json keeps
# working on another machine.
tilde() {
    # shellcheck disable=SC2088  # a literal ~, for display
    case $1 in
        "$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;;
        *) printf '%s' "$1" ;;
    esac
}

# Point LINK at TARGET, unless something else of the user's is there.
link() {
    local target=$1 linkpath=$2 cur
    mkdir -p "${linkpath%/*}"
    if [ -L "$linkpath" ]; then
        cur=$(readlink "$linkpath")
        if [ "$cur" = "$target" ]; then say "ok      $(tilde "$linkpath")"; return 0; fi
        ln -sfn "$target" "$linkpath" && say "updated $(tilde "$linkpath") -> $(tilde "$target")"
    elif [ -e "$linkpath" ]; then
        # A real directory: the copy this replaces. Keep it outside the skills
        # folder, where it would still load as a skill.
        if [ "$(cd "$linkpath" 2>/dev/null && pwd -P)" = "$target" ]; then say "ok      $(tilde "$linkpath")"; return 0; fi
        local keep
        keep=$STATE_DIR/replaced-$(date +%Y%m%d-%H%M%S)-${linkpath##*/}
        mkdir -p "$STATE_DIR"
        mv "$linkpath" "$keep" && ln -sfn "$target" "$linkpath" &&
            say "replaced $(tilde "$linkpath") (old copy kept in $(tilde "$keep"))"
    else
        ln -sfn "$target" "$linkpath" && say "linked  $(tilde "$linkpath") -> $(tilde "$target")"
    fi
}

unlink_ours() {
    local linkpath=$1
    if [ -L "$linkpath" ] && [ "$(readlink "$linkpath")" = "$2" ]; then
        rm -f "$linkpath" && say "removed $(tilde "$linkpath")"
    fi
}

# settings.json is edited by a small Python program: it keeps everything it
# does not own, and is idempotent.
settings_py() {
    command -v python3 > /dev/null || die "python3 is needed to edit $SETTINGS (or see the README for the manual steps)"
    python3 - "$@" <<'PY'
import json, os, re, shlex, sys, time

action, settings_path, state_path, root = sys.argv[1:5]
opts = dict(a.split("=", 1) for a in sys.argv[5:])
home = os.path.expanduser("~")

def tilde(p):
    if p.startswith(home + "/") and re.fullmatch(r"[A-Za-z0-9_@%+=:,./~-]+", p):
        return "~" + p[len(home):]
    return shlex.quote(p)

unspin = tilde(os.path.join(root, "bin", "unspin"))
nudge = tilde(os.path.join(root, "hooks", "nudge.sh"))
dismiss = tilde(os.path.join(root, "hooks", "dismiss.sh"))
FLOW_HOOK = re.compile(r"(flow/hooks/(pretool-nudge|prompt-dismiss|nudge|dismiss)\.sh|unspin[^ ]*/hooks/)")

def load():
    try:
        with open(settings_path) as f:
            text = f.read()
    except FileNotFoundError:
        return {}, None
    try:
        return (json.loads(text) if text.strip() else {}), text
    except json.JSONDecodeError as e:
        sys.exit(f"{settings_path} is not valid JSON ({e}); fix it first")

def save(data, original):
    if original is not None:
        backup = f"{settings_path}.bak-unspin-{time.strftime('%Y%m%d-%H%M%S')}"
        with open(backup, "w") as f:
            f.write(original)
        print(f"  backup  {tilde(backup)}")
    os.makedirs(os.path.dirname(settings_path), exist_ok=True)
    tmp = settings_path + ".tmp-unspin"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, settings_path)

def ours(cmd):
    return bool(re.search(r"unspin\S*\s+statusline", cmd or ""))

def simple(cmd):
    return re.fullmatch(r"[A-Za-z0-9_@%+=:,./~-]+( [A-Za-z0-9_@%+=:,./~-]+)*", cmd) is not None

def base_script_draws_flow(cmd):
    # A hand-made status line script that already draws the flow itself.
    for word in cmd.split():
        p = os.path.expanduser(word)
        if os.path.isfile(p) and os.path.getsize(p) < 1_000_000:
            try:
                text = open(p, errors="replace").read()
            except OSError:
                continue
            if "statusline-unspin.sh" in text or "unspin block" in text or "unspin\" block" in text:
                return p
    return None

def hook_entries(data):
    for event, entries in (data.get("hooks") or {}).items():
        for entry in entries or []:
            for h in entry.get("hooks") or []:
                yield event, entry, h

def set_hook(data, event, matcher, command):
    hooks = data.setdefault("hooks", {})
    entries = hooks.setdefault(event, [])
    found = False
    for entry in entries:
        for h in entry.get("hooks") or []:
            if FLOW_HOOK.search(h.get("command", "")):
                if not found:
                    h.update(type="command", command=command, timeout=5)
                    found = True
                else:
                    h["_drop"] = True
        entry["hooks"] = [h for h in entry.get("hooks") or [] if not h.get("_drop")]
    hooks[event] = [e for e in entries if e.get("hooks")]
    if not found:
        entry = {"hooks": [{"type": "command", "command": command, "timeout": 5}]}
        if matcher:
            entry = {"matcher": matcher, **entry}
        hooks[event].append(entry)
    return not found

def drop_hooks(data):
    removed = 0
    hooks = data.get("hooks") or {}
    for event in list(hooks):
        for entry in hooks[event] or []:
            keep = [h for h in entry.get("hooks") or [] if not FLOW_HOOK.search(h.get("command", ""))]
            removed += len(entry.get("hooks") or []) - len(keep)
            entry["hooks"] = keep
        hooks[event] = [e for e in hooks[event] or [] if e.get("hooks")]
        if not hooks[event]:
            del hooks[event]
    if "hooks" in data and not data["hooks"]:
        del data["hooks"]
    return removed

def read_state():
    try:
        with open(state_path) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}

def write_state(state):
    os.makedirs(os.path.dirname(state_path), exist_ok=True)
    with open(state_path, "w") as f:
        json.dump(state, f, indent=2)

data, original = load()
state = read_state()

if action == "install":
    changed = False
    if opts.get("statusline", "1") == "1":
        sl = data.get("statusLine") or {}
        cmd = sl.get("command", "") if sl.get("type") == "command" else ""
        rows = opts.get("rows", "")
        mine = f"{unspin} statusline" + (f" --rows {rows}" if rows else "")
        if ours(cmd):
            base = cmd.split(" -- ", 1)[1] if " -- " in cmd else ""
            new = mine + (f" -- {base}" if base else "")
            what = "status line already goes through unspin"
        elif cmd and base_script_draws_flow(cmd):
            new = cmd
            what = f"status line script {tilde(base_script_draws_flow(cmd))} draws the flow itself; left as is"
        else:
            if "statusLine" not in state:
                state["statusLine"] = data.get("statusLine")
            if cmd:
                new = mine + " -- " + (cmd if simple(cmd) else "sh -c " + shlex.quote(cmd))
                what = "status line now draws the flow under your existing one"
            else:
                new = mine
                what = "status line set to draw the flow"
        new_sl = dict(sl) if sl.get("type") == "command" else {}
        new_sl.update(type="command", command=new)
        ri = new_sl.get("refreshInterval")
        if not isinstance(ri, (int, float)) or ri > 1:
            if "refreshInterval" not in state:
                state["refreshInterval"] = ri
            new_sl["refreshInterval"] = 1
            what += ", redrawn every second"
        if new_sl != data.get("statusLine"):
            data["statusLine"] = new_sl
            changed = True
            print(f"  {what}")
        else:
            print(f"  ok      status line")
    if opts.get("hooks", "1") == "1":
        before = json.dumps(data.get("hooks"), sort_keys=True)
        set_hook(data, "PreToolUse", "Bash", f"bash {nudge}")
        set_hook(data, "UserPromptSubmit", None, f"bash {dismiss}")
        if json.dumps(data.get("hooks"), sort_keys=True) != before:
            changed = True
            print("  hooks   nudge (PreToolUse on Bash), dismiss (UserPromptSubmit)")
        else:
            print("  ok      hooks")
    if changed:
        save(data, original)
        write_state(state)

elif action == "uninstall":
    changed = False
    sl = data.get("statusLine") or {}
    cmd = sl.get("command", "") if sl.get("type") == "command" else ""
    if ours(cmd):
        if "statusLine" in state:
            prev = state["statusLine"]
            if prev:
                data["statusLine"] = prev
            else:
                data.pop("statusLine", None)
        else:
            base = cmd.split(" -- ", 1)[1] if " -- " in cmd else ""
            m = re.fullmatch(r"sh -c ('.*')", base)
            if m:
                base = shlex.split(m.group(1))[0]
            if base:
                sl = dict(sl, command=base)
                if state.get("refreshInterval", "absent") is None:
                    sl.pop("refreshInterval", None)
                data["statusLine"] = sl
            else:
                data.pop("statusLine", None)
        changed = True
        print("  status line restored")
    n = drop_hooks(data)
    if n:
        changed = True
        print(f"  removed {n} hook(s)")
    if changed:
        save(data, original)
    try:
        os.remove(state_path)
    except FileNotFoundError:
        pass

elif action == "check":
    sl = data.get("statusLine") or {}
    cmd = sl.get("command", "") if sl.get("type") == "command" else ""
    print("statusline=" + ("ours" if ours(cmd) else ("script" if cmd and base_script_draws_flow(cmd) else ("other" if cmd else "none"))))
    print("refresh=" + str(sl.get("refreshInterval", "")))
    events = {e for e, _, h in hook_entries(data) if FLOW_HOOK.search(h.get("command", ""))}
    print("hooks=" + ",".join(sorted(events)))
PY
}

# unspin started life as a skill named `flow`. A copy of that one would load
# beside this skill, so it moves out of the skills folder.
retire_old_skill() {
    local old=$CLAUDE_DIR/skills/flow keep
    [ -e "$old" ] || return 0
    [ -f "$old/statusline-flow.sh" ] || [ -f "$old/flow.sh" ] || return 0
    keep=$STATE_DIR/replaced-$(date +%Y%m%d-%H%M%S)-flow
    mkdir -p "$STATE_DIR"
    if [ -L "$old" ]; then rm -f "$old" && say "removed $(tilde "$old") (the skill's old name)"
    else mv "$old" "$keep" && say "moved the old flow skill out of the way, to $(tilde "$keep")"
    fi
}

# The Claude Code plugin brings the skill, the hooks and the mod (which
# draws in the spinner and above the prompt) by itself.
plugin_installed() {
    grep -qs '"unspin@' "$CLAUDE_DIR/plugins/installed_plugins.json"
}

setup_main() {
    local statusline='' hooks=1 skill=1 bin=1 rows='' agents=1
    while [ $# -gt 0 ]; do
        case $1 in
            --statusline) statusline=1 ;;
            --no-statusline) statusline=0 ;;
            --no-hooks) hooks=0 ;;
            --no-skill) skill=0 ;;
            --no-bin) bin=0 ;;
            --no-agents) agents=0 ;;
            --rows) rows=$2; shift ;;
            --rows=*) rows=${1#*=} ;;
            -h | --help)
                cat << EOF
usage: $PROG setup [--rows N] [--[no-]statusline] [--no-hooks] [--no-skill] [--no-bin] [--no-agents]

Links the skill into ~/.claude/skills/unspin (and ~/.agents/skills for other
agents), puts $PROG on your PATH, and adds the status line and the two hooks
to $(tilde "$SETTINGS"). Your own status line keeps working, with the flow
drawn under it. With the Claude Code plugin installed, the plugin already
brings the skill and the hooks and draws in the spinner, so only the command
is linked unless you ask for --statusline. Run it again any time; \`$PROG uninstall\`
undoes it.
EOF
                return 0 ;;
            *) die "setup: unknown option $1" ;;
        esac
        shift
    done
    if plugin_installed; then
        hooks=0 skill=0 statusline=${statusline:-0}
        step_msg "The unspin plugin is installed: its skill, hooks and spinner are already active."
    fi
    statusline=${statusline:-1}

    step_msg "Skill"
    if [ "$skill" = 1 ]; then
        retire_old_skill
        link "$ROOT" "$CLAUDE_DIR/skills/unspin"
        # Codex, Gemini CLI, Copilot CLI, Cline and Warp read the shared
        # ~/.agents/skills folder (opencode, Cursor, Amp and Goose read
        # ~/.claude/skills as well).
        if [ "$agents" = 1 ] && { [ -d "$HOME/.agents" ] || [ -d "$HOME/.codex" ] || [ -d "$HOME/.gemini" ] || [ -d "$HOME/.copilot" ]; }; then
            link "$ROOT" "$HOME/.agents/skills/unspin"
        fi
    else
        say "skipped"
    fi

    step_msg "Command"
    if [ "$bin" = 1 ]; then
        link "$ROOT/bin/unspin" "$BIN_DIR/unspin"
        case ":$PATH:" in
            *":$BIN_DIR:"*) ;;
            *) say "note    $(tilde "$BIN_DIR") is not on your PATH; add it to use \`unspin\` directly" ;;
        esac
    else
        say "skipped"
    fi

    step_msg "Claude Code settings ($(tilde "$SETTINGS"))"
    if [ "$statusline" = 1 ] || [ "$hooks" = 1 ]; then
        settings_py install "$SETTINGS" "$STATE_DIR/setup.json" "$ROOT" \
            "statusline=$statusline" "hooks=$hooks" ${rows:+"rows=$rows"} || return 1
    else
        say "skipped"
    fi

    cat << EOF

Done. New Claude Code sessions pick this up; in a running one, type /hooks
once so it reloads its hooks. To see it work, run this in Claude Code:

  ! $(tilde "$BIN_DIR")/unspin demo

or run \`unspin watch\` in a second terminal and \`unspin demo\` in this one.
EOF
}

setup_uninstall() {
    step_msg "Claude Code settings ($(tilde "$SETTINGS"))"
    if [ -f "$SETTINGS" ]; then
        settings_py uninstall "$SETTINGS" "$STATE_DIR/setup.json" "$ROOT" || return 1
    fi
    step_msg "Links"
    local d
    for d in "$CLAUDE_DIR/skills" "$HOME/.agents/skills"; do
        unlink_ours "$d/unspin" "$ROOT"
    done
    unlink_ours "$BIN_DIR/unspin" "$ROOT/bin/unspin"
    rmdir "$STATE_DIR" 2>/dev/null
    printf '\nunspin is unwired. The files themselves are still in %s.\n' "$(tilde "$ROOT")"
}

setup_doctor() {
    local good=0 bad=0 dir seen age
    pass() { good=$((good + 1)); printf '  \033[32m✔\033[0m %s\n' "$*"; }
    warn() { bad=$((bad + 1)); printf '  \033[31m✘\033[0m %s\n' "$*"; }
    info() { printf '  · %s\n' "$*"; }

    printf '%s %s in %s\n' "$PROG" "$VERSION" "$(tilde "$ROOT")"

    dir=$(flow_dir)
    if [ -d "$dir" ] && [ -w "$dir" ]; then pass "flow files go to $dir"
    elif (umask 077 && mkdir -p "$dir") 2>/dev/null; then pass "flow files go to $dir (created)"
    else warn "cannot write to $dir; set UNSPIN_DIR to a writable directory"
    fi

    if [ -L "$CLAUDE_DIR/skills/unspin" ] || [ -d "$CLAUDE_DIR/skills/unspin" ]; then
        if [ -f "$CLAUDE_DIR/skills/unspin/unspin.sh" ] && [ -f "$CLAUDE_DIR/skills/unspin/SKILL.md" ]; then pass "skill at $(tilde "$CLAUDE_DIR/skills/unspin")"
        else warn "$(tilde "$CLAUDE_DIR/skills/unspin") is there but has no unspin.sh or SKILL.md"
        fi
    elif plugin_installed; then pass "skill comes from the unspin plugin"
    else warn "no skill at $(tilde "$CLAUDE_DIR/skills/unspin"); run \`$PROG setup\`"
    fi

    if command -v unspin > /dev/null; then pass "unspin is on PATH ($(command -v unspin))"
    else info "unspin is not on PATH (fine for Claude Code, handy for \`unspin watch\`)"
    fi

    if command -v python3 > /dev/null && [ -f "$SETTINGS" ]; then
        local out sl refresh hooks
        out=$(settings_py check "$SETTINGS" "$STATE_DIR/setup.json" "$ROOT" 2>&1)
        sl=$(printf '%s\n' "$out" | sed -n 's/^statusline=//p')
        refresh=$(printf '%s\n' "$out" | sed -n 's/^refresh=//p')
        hooks=$(printf '%s\n' "$out" | sed -n 's/^hooks=//p')
        case $sl in
            ours) pass "status line goes through unspin" ;;
            script) pass "your status line script draws the flow itself" ;;
            *)
                if plugin_installed; then info "status line not used for flows (the plugin draws them)"
                elif [ "$sl" = other ]; then warn "status line does not draw flows; run \`$PROG setup\`"
                else warn "no status line configured; run \`$PROG setup\`"
                fi ;;
        esac
        case $sl:$refresh in
            ours:1 | ours:1.0 | script:1 | script:1.0) pass "status line redraws every second" ;;
            ours:* | script:*) warn "status line refreshInterval is '${refresh:-unset}'; flows only move with 1" ;;
        esac
        if plugin_installed; then pass "hooks and the spinner come from the unspin plugin"
        else
            case $hooks in
                *PreToolUse*UserPromptSubmit*) pass "hooks: nudge and dismiss" ;;
                *) warn "hooks missing (${hooks:-none}); run \`$PROG setup\`" ;;
            esac
        fi
    else
        info "no settings to check ($(tilde "$SETTINGS"), python3)"
    fi

    seen=$dir/.seen
    if [ -e "$seen" ]; then
        age=$(( $(date +%s) - $(date -r "$seen" +%s 2>/dev/null || stat -c %Y "$seen" 2>/dev/null || echo 0) ))
        if [ "$age" -lt 30 ]; then pass "a status line drew a flow ${age}s ago"
        else info "a status line last drew a flow ${age}s ago"
        fi
    else
        info "no status line has drawn a flow yet (try \`unspin demo\` inside Claude Code)"
    fi

    local awk_v
    awk_v=$(awk --version 2>/dev/null | head -n 1)
    [ -n "$awk_v" ] || awk_v=$(awk -W version 2>/dev/null | head -n 1)
    info "awk: ${awk_v:-unknown}; bash: ${BASH_VERSION}; zsh: $(zsh --version 2>/dev/null || echo none)"
    printf '\n%s fine, %s to fix\n' "$good" "$bad"
    [ "$bad" -eq 0 ]
}
