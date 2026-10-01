#!/usr/bin/env bash
#
# vorssaint-dev-prs.sh — what happened to Aryan's upstream PRs that `my-changes` carries.
#
# Every fork commit whose subject ends in "(PR <n>)" is a PR filed on
# vorssaint/vorssaint-utils and cherry-picked early. Prints one tab-separated line each:
#   <sha> <n> <state> <feedback>
# state is MERGED, CLOSED (closed without merging), OPEN, or UNKNOWN when gh can't reach
# GitHub. feedback is the newest review or comment from someone other than Aryan, if any.
#
# --notify also posts a macOS notification for each PR whose state or feedback changed
# since the last --notify run (remembered in $STATE). Used by the nightly check and by
# vorssaint-dev-update.sh, which drops MERGED commits before rebasing.
set -uo pipefail

REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
UPSTREAM="vorssaint/vorssaint-utils"
ME="Aryan-Saini"
MIRROR_BRANCH="${VORSSAINT_DEV_MIRROR_BRANCH:-main}"
WORK_BRANCH="${VORSSAINT_DEV_BRANCH:-my-changes}"
STATE="$HOME/.local/state/vorssaint-dev/prs.tsv"
export PATH="/opt/homebrew/bin:/usr/bin:/bin:$PATH"
cd "$REPO" || exit 1

notify=0; [[ "${1:-}" == "--notify" ]] && notify=1
mkdir -p "$(dirname "$STATE")"; touch "$STATE"

# Newest feedback from someone else: "<timestamp> <author>: <first line>". Inline review
# comments count; an empty "commented" review is skipped since its inline comments say it all.
feedback() {
    local n="$1"
    {
        gh api "repos/$UPSTREAM/issues/$n/comments" --jq '.[] | [.created_at, .user.login, .body] | @tsv'
        gh api "repos/$UPSTREAM/pulls/$n/comments" --jq '.[] | [.created_at, .user.login, .body] | @tsv'
        gh api "repos/$UPSTREAM/pulls/$n/reviews" \
            --jq '.[] | select(.body != "" or .state != "COMMENTED") | [.submitted_at, .user.login, (if .body == "" then "review: " + .state else .body end)] | @tsv'
    } 2>/dev/null | awk -F'\t' -v me="$ME" '$2 != me' | sort | tail -1 \
        | awk -F'\t' '{ printf "%s %s: %s", $1, $2, substr($3, 1, 160) }'
}

git log --reverse --format='%H%x09%s' "$MIRROR_BRANCH..$WORK_BRANCH" \
| sed -nE 's/^([0-9a-f]+)\t.*\(PR ([0-9]+)\)$/\1 \2/p' \
| while read -r sha n; do
    state="$(gh pr view "$n" -R "$UPSTREAM" --json state --jq .state 2>/dev/null || echo UNKNOWN)"
    note=""; [[ "$state" == "UNKNOWN" ]] || note="$(feedback "$n")"
    printf '%s\t%s\t%s\t%s\n' "$sha" "$n" "$state" "$note"

    [[ "$notify" == "1" && "$state" != "UNKNOWN" ]] || continue
    seen="$(awk -F'\t' -v n="$n" '$1 == n { print $2 "\t" $3 }' "$STATE")"
    [[ "$seen" == "$state"$'\t'"$note" ]] && continue
    { awk -F'\t' -v n="$n" '$1 != n' "$STATE"; printf '%s\t%s\t%s\n' "$n" "$state" "$note"; } > "$STATE.tmp" \
        && mv "$STATE.tmp" "$STATE"
    [[ "$state" == "OPEN" && -z "$note" ]] && continue
    case "$state" in
        MERGED) body="Merged upstream. The next update drops the fork's copy." ;;
        CLOSED) body="Closed without merging. The fork keeps carrying it." ;;
        *)      body="New feedback: ${note#* }" ;;
    esac
    /usr/bin/osascript -e "display notification \"${body//\"/\\\"}\" with title \"Vorssaint PR $n\"" >/dev/null 2>&1 || true
done
