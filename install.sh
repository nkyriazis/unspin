#!/usr/bin/env bash
# Install unspin for Claude Code (and the skill for other agents).
#
#   curl -fsSL https://raw.githubusercontent.com/nkyriazis/unspin/main/install.sh | bash
#   curl -fsSL .../install.sh | bash -s -- --version v1.0.0 --rows 3
#   ./install.sh               from a clone, installs that working copy
#
# Files go to ~/.local/share/unspin (UNSPIN_HOME to change it), then
# `unspin setup` links them in; any option not listed here is passed to it.
# Run it again to update. `unspin uninstall` undoes the setup.
set -euo pipefail

REPO=nkyriazis/unspin
HOME_DIR=${UNSPIN_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/unspin}
REF=''
SETUP=1
PASS=()
while [ $# -gt 0 ]; do
    case $1 in
        --version) REF=$2; shift ;;
        --version=*) REF=${1#*=} ;;
        --no-setup) SETUP=0 ;;
        *) PASS+=("$1") ;;
    esac
    shift
done

say() { printf '\033[1m%s\033[0m\n' "$*"; }
die() { printf 'unspin install: %s\n' "$*" >&2; exit 1; }

for tool in awk tar; do command -v "$tool" > /dev/null || die "needs $tool"; done

tmp=$(mktemp -d "${TMPDIR:-/tmp}/unspin-install.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# Run from a file (./install.sh in a clone), it installs that clone. Piped
# into bash it has no file and no directory of its own, so it downloads.
here=''
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    here=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P || true)
fi
if [ -z "$REF" ] && [ -n "$here" ] && [ -f "$here/skills/unspin/unspin.sh" ]; then
    src=$here/skills/unspin
    say "Installing unspin from $here"
else
    command -v curl > /dev/null || die "needs curl"
    if [ -z "$REF" ]; then
        # No release yet, or the API refusing us (rate limits), means main.
        REF=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null |
            sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1) || REF=''
        REF=${REF:-main}
    fi
    say "Downloading unspin $REF"
    curl -fsSL "https://codeload.github.com/$REPO/tar.gz/$REF" | tar -xz -C "$tmp" ||
        die "could not download $REPO at $REF"
    src=$(find "$tmp" -mindepth 3 -maxdepth 3 -type d -path '*/skills/unspin' | head -n 1) || src=''
    [ -n "$src" ] && [ -f "$src/unspin.sh" ] || die "the download has no skills/unspin"
fi

# Swap the new files in whole, so a failed copy leaves the old ones working.
mkdir -p "$(dirname "$HOME_DIR")"
rm -rf "$HOME_DIR.new"
cp -R "$src" "$HOME_DIR.new"
chmod +x "$HOME_DIR.new/bin/unspin" "$HOME_DIR.new/hooks/"*.sh
rm -rf "$HOME_DIR.old"
if [ -e "$HOME_DIR" ]; then mv "$HOME_DIR" "$HOME_DIR.old"; fi
mv "$HOME_DIR.new" "$HOME_DIR"
rm -rf "$HOME_DIR.old"
say "unspin $("$HOME_DIR/bin/unspin" version | cut -d' ' -f2) is in $HOME_DIR"

if [ "$SETUP" = 1 ]; then
    echo
    "$HOME_DIR/bin/unspin" setup ${PASS[@]+"${PASS[@]}"}
fi
