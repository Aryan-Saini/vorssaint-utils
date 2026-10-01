#!/usr/bin/env bash
#
# vorssaint-dev-check-update.sh — check whether upstream Vorssaint is ahead of the
# local `main` mirror and flag it. Run nightly by the fleet automations dispatcher
# (~/fleet/automations/mac/tools/vorssaint-dev-update); safe to run anytime (it
# only fetches).
#
# Same shape as Peekaboo's check: rings cmux's bell when cmux DEV is running,
# otherwise posts a macOS notification, and only when the pending count changes.
set -uo pipefail

REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
MIRROR_BRANCH="${VORSSAINT_DEV_MIRROR_BRANCH:-main}"
STATE_FILE="/tmp/vorssaint-dev-update-available"
CMUX_REPO="${CMUX_REPO:-$HOME/tools/cmux}"
export PATH="/opt/homebrew/bin:/usr/bin:/bin:$PATH"

cd "$REPO" || exit 1
git rev-parse --git-dir >/dev/null 2>&1 || exit 0
git fetch --quiet origin 2>/dev/null || exit 0
# PR merges, closes and new feedback notify on their own, even with nothing upstream.
"$REPO/scripts/vorssaint-dev-prs.sh" --notify >/dev/null
behind="$(git rev-list --count "${MIRROR_BRANCH}..origin/${MIRROR_BRANCH}" 2>/dev/null || echo 0)"

if [[ "$behind" == "0" ]]; then
    rm -f "$STATE_FILE"
    exit 0
fi

previous="$(cat "$STATE_FILE" 2>/dev/null || true)"
echo "$behind" > "$STATE_FILE"
[[ "$previous" == "$behind" ]] && exit 0

title="Vorssaint update available"
plural="commit"; [[ "$behind" != "1" ]] && plural="commits"
body="$behind new $plural upstream. Run \"Update Vorssaint (dev)\" from the cmux palette, or vorssaint-dev-update."

# 1) cmux bell, best effort, only if the cmux DEV build is running.
bell_ok=0
if [[ -S "/tmp/cmux-debug-dev.sock" && -x "$CMUX_REPO/scripts/cmux-debug-cli.sh" ]]; then
    CMUX_TAG=dev "$CMUX_REPO/scripts/cmux-debug-cli.sh" notify --workspace "workspace:1" \
        --title "$title" --body "$body" >/dev/null 2>&1 && bell_ok=1
fi
# 2) macOS Notification Center, the reliable baseline.
if [[ "$bell_ok" == "0" ]]; then
    /usr/bin/osascript -e "display notification \"${body//\"/\\\"}\" with title \"$title\"" >/dev/null 2>&1 || true
fi
