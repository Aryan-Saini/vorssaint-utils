#!/usr/bin/env bash
#
# vorssaint-dev-update.sh — pull upstream Vorssaint into this fork and reinstall.
#
# Same flow as Peekaboo's scripts/peekaboo-dev-update.sh: auto-commit tracked local
# work -> check Aryan's upstream PRs (vorssaint-dev-prs.sh) -> fast-forward the `main`
# mirror -> rebase `my-changes` onto it, dropping PR commits upstream merged (headless
# Claude resolves conflicts, and finishes a rebase a killed run left behind; aborts safely
# if it can't) -> verify the fork's patches
# survived -> `./build.sh --dev --install` -> relaunch if it was running.
# Nothing changes until you run this, so upstream never breaks the installed app by
# surprise. `--force` rebuilds even when upstream has nothing new.
#
# Installs /Applications/Vorssaint DEV.app (bundle id com.vorssaint.utils.dev, which
# never self-updates), optimized, and signed with Aryan's pinned Apple Development
# identity, like Peekaboo. Personal, not the Syncafy Developer ID: that is company
# signing. The designated requirement stays fixed, so Accessibility grants survive rebuilds.
set -uo pipefail

REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
WORK_BRANCH="${VORSSAINT_DEV_BRANCH:-my-changes}"
MIRROR_BRANCH="${VORSSAINT_DEV_MIRROR_BRANCH:-main}"
LOG="${VORSSAINT_DEV_LOG:-/tmp/vorssaint-dev-update.log}"
APP="/Applications/Vorssaint DEV.app"
PROCESS="VorssaintDeveloper"
# The leaf the designated requirement pins; the team on this cert is Syncafy's.
SIGNER="Apple Development: Aryan Saini (D949RXKYAM)"
# Apple Development: Aryan Saini (D949RXKYAM). A hash, so a renewed cert
# with the same name can never be picked by accident.
export VORSSAINT_SIGN_IDENTITY="${VORSSAINT_SIGN_IDENTITY:-BD77994E73F3EFFE094B181DC4302AF23AF5D6AD}"
export VORSSAINT_DEV_OPTIMIZED=1
export PATH="/opt/homebrew/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
cd "$REPO" || exit 1

log() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*"; }
notify() {
    log "$1 — $2"
    /usr/bin/osascript -e "display notification \"${2//\"/\\\"}\" with title \"${1//\"/\\\"}\"" >/dev/null 2>&1 || true
}
fail() { notify "Vorssaint update failed" "$1"; exit 1; }
rebase_in_progress() { [[ -d .git/rebase-merge || -d .git/rebase-apply ]]; }

# The fork's patches. The build is refused if one vanished in a rebase.
patches_intact() {
    grep -q 'VORSSAINT_SIGN_IDENTITY' build.sh \
    && grep -q 'Vorssaint DEV' build.sh \
    && grep -q 'DEV_ICON_TINT' build.sh \
    && grep -q 'VORSSAINT_ICON_TINT' Tools/MakeIcon.swift \
    && grep -q 'developerBadged' Sources/Vorssaint/App/StatusItemController.swift
}

resolve_rebase_with_claude() {
    local claude_bin; claude_bin="$(command -v claude 2>/dev/null || true)"
    [[ -n "$claude_bin" ]] || { log "claude not on PATH; cannot auto-resolve."; return 1; }
    log "Asking Claude to resolve the rebase…"
    ( cd "$REPO" && "$claude_bin" -p "You are in the git repository at ${REPO}, a personal fork of \
vorssaint/vorssaint-utils. A 'git rebase ${MIRROR_BRANCH}' of branch '${WORK_BRANCH}' stopped on conflicts. \
Resolve every conflict so the fork's changes on '${WORK_BRANCH}' are preserved on top of upstream. \
Two kinds of commits live on '${WORK_BRANCH}'. DEV patches must survive every rebase: in build.sh \
the Vorssaint DEV name, VORSSAINT_DEV_OPTIMIZED, VORSSAINT_SIGN_IDENTITY and DEV_ICON_TINT (plus the \
icon.json tint block), VORSSAINT_ICON_TINT in Tools/MakeIcon.swift, and developerBadged in \
Sources/Vorssaint/App/StatusItemController.swift. Commits whose subject ends in '(PR <number>)' are \
Aryan's upstream PRs cherry-picked early: if upstream already contains that feature, even edited by \
reviewers, keep upstream's version and git rebase --skip the commit. Their status on GitHub \
(sha, PR, state, newest feedback): ${PR_STATUS:-unknown}. Keep OPEN and CLOSED ones, adapting them to \
upstream's current code. For each step: edit the files to a correct merge, \
git add them, git rebase --continue. Use git rebase --skip only if the commit is already fully \
upstream. Never git rebase --abort, never push. Finish with git status showing no rebase in progress." \
        --dangerously-skip-permissions ) || true
    ! rebase_in_progress && [[ -z "$(git diff --name-only --diff-filter=U)" ]]
}

log "Repo: $REPO (branch=$WORK_BRANCH)"

# GIT_EDITOR=true so neither the rebase below nor Claude's --continue waits on an editor.
export GIT_EDITOR=true

# A rebase left behind by an earlier run that died mid-resolution (Terminal closed,
# fleet-update timeout) would otherwise block every later run. Hand it to Claude to
# finish; if it can't, abort, which restores the branch to before that run.
if rebase_in_progress; then
    [[ "$(cat .git/rebase-merge/head-name .git/rebase-apply/head-name 2>/dev/null)" == "refs/heads/$WORK_BRANCH" ]] \
        || fail "a rebase of another branch is in progress; finish or abort it by hand"
    notify "Vorssaint update: resuming" "A previous rebase was left unfinished, launching Claude…"
    PR_STATUS="$(scripts/vorssaint-dev-prs.sh)"
    resolve_rebase_with_claude || { git rebase --abort >/dev/null 2>&1; fail "leftover rebase not resolved, aborted; branch restored"; }
fi
[[ "$(git branch --show-current)" == "$WORK_BRANCH" ]] \
    || fail "not on $WORK_BRANCH (on '$(git branch --show-current)'); check out $WORK_BRANCH first"

# Tracked changes only, so stray untracked files never ride along.
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
    log "Uncommitted tracked changes — auto-committing before update."
    git add -u && git commit -q -m "chore: auto-commit local changes before vorssaint dev update" \
        || fail "auto-commit failed"
fi

git fetch --quiet origin || fail "git fetch failed (network?)"
behind="$(git rev-list --count "${MIRROR_BRANCH}..origin/${MIRROR_BRANCH}" 2>/dev/null || echo 0)"

# What happened to each PR the fork carries. Merged ones are upstream now, so their
# fork copies are dropped instead of left for the rebase to trip over.
PR_STATUS="$(scripts/vorssaint-dev-prs.sh --notify)"
while IFS=$'\t' read -r _ n state note; do
    [[ -n "${n:-}" ]] && log "PR $n: $state${note:+ (latest: ${note#* })}"
done <<< "$PR_STATUS"
merged="$(awk -F'\t' '$3 == "MERGED" { print $1 }' <<< "$PR_STATUS")"
merged_prs="$(awk -F'\t' '$3 == "MERGED" { printf "%s#%s", sep, $2; sep = ", " }' <<< "$PR_STATUS")"

if [[ "$behind" == "0" && -z "$merged" && "${1:-}" != "--force" ]]; then
    notify "Vorssaint is up to date" "No new upstream commits."
    exit 0
fi
log "Upstream is $behind commit(s) ahead."

# Fast-forward the mirror as a ref update, never checking it out.
if [[ "$behind" != "0" ]]; then
    git fetch --quiet origin "${MIRROR_BRANCH}:${MIRROR_BRANCH}" \
        || fail "$MIRROR_BRANCH could not fast-forward (committed to it?)"
fi

# Turn each merged PR's pick into a drop. The todo abbreviates to at least 7 characters.
drop_merged="$(mktemp)"; trap 'rm -f "$drop_merged"' EXIT
{
    echo '#!/bin/sh'
    for sha in $merged; do echo "sed -i '' -E 's/^pick ${sha:0:7}[0-9a-f]* /drop ${sha:0:7} /' \"\$1\""; done
} > "$drop_merged"
chmod +x "$drop_merged"
[[ -n "$merged" ]] && log "Dropping merged PR commit(s): $merged_prs"
if ! GIT_SEQUENCE_EDITOR="$drop_merged" git rebase -q -i "$MIRROR_BRANCH"; then
    notify "Vorssaint update: resolving conflicts" "Rebase hit conflicts, launching Claude…"
    resolve_rebase_with_claude || { git rebase --abort >/dev/null 2>&1; fail "rebase conflict not resolved, aborted; branch untouched"; }
fi

# Trust the result, not Claude's say-so.
git merge-base --is-ancestor "$MIRROR_BRANCH" "$WORK_BRANCH" \
    || fail "$WORK_BRANCH is not on top of $MIRROR_BRANCH after the rebase; not building"
[[ "$(git branch --show-current)" == "$WORK_BRANCH" ]] || fail "ended off $WORK_BRANCH; not building"
patches_intact || fail "a fork patch was lost in the rebase; restore it before building"

security find-identity -v -p codesigning | grep -q "$VORSSAINT_SIGN_IDENTITY" \
    || fail "signing identity $VORSSAINT_SIGN_IDENTITY is not in the keychain"

was_running=0
pgrep -x "$PROCESS" >/dev/null && was_running=1

log "Building and installing (build output: $LOG)…"
if ! ./build.sh --dev --install >>"$LOG" 2>&1; then
    # build.sh stops the app before installing. Bring back whatever is installed if it is
    # still validly signed, so a failed update never leaves the menu bar app dead.
    if [[ "$was_running" == "1" ]] && codesign --verify --deep --strict "$APP" >/dev/null 2>&1; then
        open "$APP"
        fail "build or install failed, previous app relaunched; see $LOG"
    fi
    fail "build or install failed and $APP is missing or badly signed; see $LOG"
fi
codesign -d -r- "$APP" 2>&1 | grep -qF "$SIGNER" || fail "installed app is not signed by $SIGNER"
# Pre-rename bundle, same bundle id; two copies would confuse Launch Services.
rm -rf "/Applications/Vorssaint (Developer).app"
[[ "$was_running" == "1" ]] && open "$APP"

rm -f /tmp/vorssaint-dev-update-available
# Off-machine backup of the fork. A rebase rewrites the branch, hence the lease.
git push --quiet --force-with-lease fork "$WORK_BRANCH" >>"$LOG" 2>&1 \
    || log "push to fork failed (not fatal), see $LOG"
notify "Vorssaint updated" "Pulled $behind commit(s), rebuilt and reinstalled.${merged_prs:+ Dropped merged $merged_prs.}"
