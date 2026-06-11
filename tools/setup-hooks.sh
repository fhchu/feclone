#!/usr/bin/env bash
# One-time setup for contributors after cloning.
#
# Installs lefthook (if it isn't already on PATH) and wires up the git hooks
# so the pre-push unit-test gate runs. Safe to re-run.
set -euo pipefail

# This script lives in tools/; operate from the repo root.
cd "$(dirname "$0")/.."

if ! command -v lefthook >/dev/null 2>&1; then
	echo "lefthook not found — attempting to install it…"
	if command -v brew >/dev/null 2>&1; then
		brew install lefthook
	elif command -v npm >/dev/null 2>&1; then
		npm install -g lefthook
	elif command -v go >/dev/null 2>&1; then
		go install github.com/evilmartians/lefthook@latest
	else
		cat <<'EOF'
✗ Could not auto-install lefthook (no brew/npm/go found).
  Install it manually, then re-run this script:
    macOS:  brew install lefthook
    Node:   npm install -g lefthook
    Go:     go install github.com/evilmartians/lefthook@latest
    Other:  https://github.com/evilmartians/lefthook/blob/master/docs/install.md
EOF
		exit 1
	fi
fi

# Writes .git/hooks/* so the hooks in lefthook.yml fire.
lefthook install
echo "✓ Git hooks installed — 'git push' will now run the unit tests."

# Friendly nudge if Godot can't be found, since the pre-push hook will skip.
if [[ -z "${GODOT_BIN:-}" ]] && ! command -v godot >/dev/null 2>&1; then
	cat <<'EOF'

Note: Godot isn't on your PATH, so the pre-push hook will SKIP the tests
(with a warning) until you add `godot` to PATH or set GODOT_BIN. For example,
add this to your shell profile (adjust the path to your install):
  export GODOT_BIN="/Applications/Godot.app/Contents/MacOS/Godot"
EOF
fi
