---
name: unspin
description: Show the steps and progress of batched shell commands live, in Claude Code's spinner, above the prompt or in the status line, so the user watches the work instead of a spinner. Use whenever you write a compound command with control flow or several dependent steps, and for any loop, download, build, crawl, wait or background job that runs longer than a few seconds.
---

The user cannot see inside a running shell command, only its text and then a spinner. A batched command hides the path it took. `unspin.sh`, in this skill's directory, marks the steps of a command in a per-session file that unspin redraws for the user every second, so they watch the flow instead of the spinner.

## Why batch at all

Each call-and-read round trip costs time and tokens. When the next step's decision is mechanical (an exit code, a grep hit, a file existing), encode it in the command and let the shell take the branch.

The cost is committing to the logic before seeing any output, so weigh it per task. A wrong branch in read-only probing is free, while an irreversible or outward-facing step (deleting, pushing, deploying, sending) should not sit behind a branch you never saw taken. Prepare and verify, then stop with a `note` and hand the last step back. When the next step needs judgment (reading a trace, choosing between hypotheses), that is a round trip by nature, so stop there.

Single commands are never instrumented.

## Helper

Source `unspin.sh` by its full path. It works in bash and zsh.

```bash
source "${CLAUDE_SKILL_DIR}/unspin.sh"
flow "Find what holds port 8080" 4    # new flow; the total is optional
step "reading ports config"
grep -q 8080 conf/ports.yaml && ok "declared in ports.yaml" || fail "not declared"
run "listing listeners" ss -ltnp 'sport = :8080'
note "pid 4121 is a stale dev server"
```

`${CLAUDE_SKILL_DIR}` is the directory this SKILL.md is in. If your agent leaves it unfilled, write that directory's path instead (usually `~/.claude/skills/unspin` or `~/.agents/skills/unspin`).

| Call | Meaning |
|---|---|
| `flow "Title" [N]` | Starts a new flow and replaces the previous one |
| `step "msg"` | Opens a step. This shell's open step is closed as ✔ first |
| `ok ["detail"]` / `fail ["detail"]` | Closes the open step |
| `note "msg"` | Side note, not a step |
| `run "msg" cmd…` | Step around one command, closed by its exit status, which it returns |
| `run -l "msg" cmd…` | Same, and the command's latest output line shows live under the step |
| `run -p "msg" cmd…` | Same as `-l`, and counts in the output (`[3/10]`, `45%`) drive a bar |
| `run -q "msg" cmd…` | Output goes to a log. Prints one line on success, the tail and the log path on failure |
| `progress N [TOTAL] ["label"]` | Updates the open step in place. A bar with a total, a bare count without one. Throttled, so call it on every iteration |
| `… \| flow_lines [-p] [TOTAL] ["label"] \| …` | Passes stdin through and counts lines as progress (`-p` reads counts from the lines instead). Without a label the latest line shows |
| `flow_each [-j N] "msg" ITEM… -- cmd…` | Runs cmd once per item with one bar, the current item and a failure tally. `{}` in cmd is the item, else the item is appended. `-j N` runs N at once. With no items it reads them from stdin, one per line. Returns 1 if any failed and lists them |
| `flow_wait [-t SECS] [-i SECS] "msg" -- cmd…` | Retries cmd every `-i` seconds (1) until it succeeds or `-t` runs out (60), with a bar for the time |

Steps show their elapsed time live, bars with a total show an ETA, and a closed step keeps its final count (`✔ scanning 120/120 2.3s`). A step whose shell is killed before closing shows as interrupted.

## Progress is the default

A step without progress is the spinner again, one level down. Give every step that may run longer than a few seconds a progress indication, without being asked.

- **Prefer the helpers.** A loop over items is `flow_each`. A wait is `flow_wait`. A long build, install or test run is `run -l`, or `run -p` when the tool prints counts (ninja, cargo, docker build, pytest). A noisy command whose output you don't need in full is `run -q`.
- **Bar over count.** Find the total when it is cheap (list the items first, read the "N items" line a tool prints, count files) and pass it. Use a bare count only when no total can be known.
- **Name the current item in the label**, plus a failure tally when there is one: `progress 17 172 "Mathimatika_G.pdf · 2 failed"`. The user should see what is happening, not just that something is.
- **Update on every item, including skips.** A resumed job that skips 900 items and then shows 901/2000 looks stuck. Don't filter the lines progress counts from.
- **Make your own tools emit progress.** When you write the script being run, give it one line per item in a parseable shape (`[i/N] status item`), counting skipped items too, and run it with `run -p`, or pipe it through `flow_lines -p`.
- **Break up long items.** If one item takes minutes (crawling a site, a big download), have the tool report sub-progress too, such as every 10 files, and show it in the label while the outer bar holds.
- **Waits count.** A poll loop waiting on a condition shows what it is waiting for and how far along it is, not a silent `sleep`.
- **Background runs too.** A long job in `run_in_background` keeps writing progress, which is how the user watches it while you do other things.

The bar is for the user. Keep reading the real output yourself, and log it to a file when it is long.

The helper's EXIT trap closes a step left open (✘ on a non-zero exit), so a crashed script never looks like it's still running. Command output still goes to stdout for you to read. The flow lines are for the user.

## Parallel steps

Each `run … &` gets its own row, and the rows run side by side.

```bash
run "unit tests" npm test &
run "lint" npm run lint &
wait
```

## Scripts in other languages

Once `unspin.sh` is sourced, `$UNSPIN_FILE` and `$UNSPIN_STEP` are exported, so a Python or Node script started inside a step can report into it by appending a line such as `% 17/172 Mathimatika_G.pdf` to `$UNSPIN_FILE` (put `id=$UNSPIN_STEP ` before the count when it is set), or by running `"${CLAUDE_SKILL_DIR}/bin/unspin" progress 17 172 Mathimatika_G.pdf`. Plain lines appended to the file work from anywhere: `▶ `, `✔ `, `✘ `, `· `, `% ` followed by text.

## One flow per task

A flow covers one logical task, not one Bash call. When a follow-up command continues the same task, source the helper and call `step` without `flow`, and the new steps append (step 7/9). Call `flow` again only when the task changes. The finished flow stays on screen until the user's next prompt, then clears.

## Subagents

Inside a subagent, don't instrument. Subagents get the same session ID, so they write to the same file, and a subagent's `flow` would wipe the main session's flow. Its work comes back to the main session as a summary anyway.

## Demo

`unspin demo` plays a short made-up flow (a release with a failing test, two parallel builds and a wait) so the user can see what unspin looks like. When they ask for the demo, run exactly `unspin demo` and nothing else. The plugin and the installer put `unspin` on PATH. It prints the flow it showed, so you can tell them in one sentence how it went.
