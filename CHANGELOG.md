# Changelog

## 1.0.0

The first public release. unspin grew out of a personal Claude Code skill named `flow`.

- A Claude Code plugin whose mod puts the running step into Claude Code's spinner and draws the flow above the prompt, with no settings to edit (Claude Code 2.1.287 or newer).
- The status line route for older versions and other setups: `unspin setup` wraps your existing status line, and `unspin block` serves your own script.
- Timestamped events, so the display shows live elapsed time, durations and an ETA for every bar.
- Steps whose shell died show as interrupted instead of running forever.
- Parallel steps with `run … &`, each on its own row; running and failed steps stay in view.
- New helpers: `flow_each` (a loop with one bar, `-j` for parallel jobs), `flow_wait` (retry with a time bar), `run -l`, `run -p` and `run -q`, and `flow_lines -p`.
- Progress counts with units (`1.2G/4G`, `12s/60s`) and percentages.
- Works under bash 3.2 to 5.3 and zsh, and renders with gawk, mawk, busybox awk and BSD awk.
- `unspin watch`, `unspin tmux` and a short stderr echo for agents without a live status line.
- `unspin demo` plays a made-up release. In a terminal it draws the flow in place, and under an agent it prints the flow at the end for the agent to read.
- An installer, `unspin setup`, `unspin doctor` and `unspin uninstall`.
