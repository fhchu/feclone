#!/usr/bin/env bash
# Runs the GUT unit-test suite headless. Single source of truth for how the
# tests are executed, shared by the lefthook pre-push hook and CI.
#
# The Godot binary is resolved from $GODOT_BIN, then `godot`/`godot4` on PATH.
# When Godot can't be found:
#   - default (local hook): SKIP with a warning and exit 0, so contributors
#     without Godot installed aren't blocked from pushing (CI is the backstop).
#   - with --require (CI):  FAIL with exit 1.
set -euo pipefail

# This script lives in tools/; run everything from the repo root.
cd "$(dirname "$0")/.."

require_godot=0
if [[ "${1:-}" == "--require" || "${REQUIRE_GODOT:-}" == "1" ]]; then
	require_godot=1
fi

find_godot() {
	if [[ -n "${GODOT_BIN:-}" ]]; then
		echo "$GODOT_BIN"
		return 0
	fi
	local candidate
	for candidate in godot godot4; do
		if command -v "$candidate" >/dev/null 2>&1; then
			echo "$candidate"
			return 0
		fi
	done
	return 1
}

if ! GODOT="$(find_godot)"; then
	if [[ "$require_godot" == 1 ]]; then
		echo "✗ Godot not found (set \$GODOT_BIN or put 'godot' on PATH)." >&2
		exit 1
	fi
	echo "⚠  Godot not found (set \$GODOT_BIN or put 'godot' on PATH) —"
	echo "   skipping local unit tests. CI will still run them."
	exit 0
fi

echo "▶  Running unit tests with: $GODOT"

# Import assets so scenes/textures load (needed on a fresh clone; a no-op once
# the cache is warm).
"$GODOT" --headless --import

# Run GUT, streaming output live while capturing it. GUT only exits non-zero
# for failed *assertions* — a test script that fails to PARSE is silently
# skipped — so we also fail the run if any script failed to load.
output="$(mktemp)"
trap 'rm -f "$output"' EXIT

set +e
"$GODOT" --headless -s addons/gut/gut_cmdln.gd -gexit 2>&1 | tee "$output"
status=${PIPESTATUS[0]}
set -e

if [[ "$status" -ne 0 ]]; then
	exit "$status"
fi

if grep -qE "Failed to load script|Could not preload resource script" "$output"; then
	echo "✗ A test script failed to load (parse error) — see output above." >&2
	exit 1
fi

echo "✓ All unit tests passed."
