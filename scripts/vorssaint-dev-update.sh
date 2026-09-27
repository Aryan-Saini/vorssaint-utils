#!/usr/bin/env bash
#
# vorssaint-dev-update.sh — pull upstream Vorssaint into this fork and reinstall.
#
# Same flow as Peekaboo's scripts/peekaboo-dev-update.sh: auto-commit tracked local
# work -> fast-forward the `main` mirror -> rebase `my-changes` onto it (headless
# Claude resolves conflicts; aborts safely if it can't) -> verify the fork's patches
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
    && grep -q 'developerBadged' Sources/Vorssaint/App/StatusItemController.swift
}

resolve_rebase_with_claude() {
    local claude_bin; claude_bin="$(command -v claude 2>/dev/null || true)"
    [[ -n "$claude_bin" ]] || { log "claude not on PATH; cannot auto-resolve."; return 1; }
    log "Asking Claude to resolve the rebase…"
    ( cd "$REPO" && "$claude_bin" -p "You are in the git repository at ${REPO}, a personal fork of \
vorssaint/vorssaint-utils. A 'git rebase ${MIRROR_BRANCH}' of branch '${WORK_BRANCH}' stopped on conflicts. \
Resolve every conflict so the fork's changes on '${WORK_BRANCH}' are preserved on top of upstream. \
The fork's build.sh patch (the Vorssaint DEV name, \
VORSSAINT_DEV_OPTIMIZED and VORSSAINT_SIGN_IDENTITY) must survive. For each step: edit the files to a correct merge, \
git add them, git rebase --continue. Use git rebase --skip only if the commit is already fully \
upstream. Never git rebase --abort, never push. Finish with git status showing no rebase in progress." \
        --dangerously-skip-permissions ) || true
    ! rebase_in_progress && [[ -z "$(git diff --name-only --diff-filter=U)" ]]
}

log "Repo: $REPO (branch=$WORK_BRANCH)"

rebase_in_progress && fail "a rebase is already in progress; finish or abort it by hand"
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
if [[ "$behind" == "0" && "${1:-}" != "--force" ]]; then
    notify "Vorssaint is up to date" "No new upstream commits."
    exit 0
fi
log "Upstream is $behind commit(s) ahead."

# Fast-forward the mirror as a ref update, never checking it out.
if [[ "$behind" != "0" ]]; then
    git fetch --quiet origin "${MIRROR_BRANCH}:${MIRROR_BRANCH}" \
        || fail "$MIRROR_BRANCH could not fast-forward (committed to it?)"
fi

if ! git rebase -q "$MIRROR_BRANCH"; then
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
./build.sh --dev --install >>"$LOG" 2>&1 || fail "build or install failed, see $LOG"
codesign -d -r- "$APP" 2>&1 | grep -qF "$SIGNER" || fail "installed app is not signed by $SIGNER"
# Pre-rename bundle, same bundle id; two copies would confuse Launch Services.
rm -rf "/Applications/Vorssaint (Developer).app"
[[ "$was_running" == "1" ]] && open "$APP"

rm -f /tmp/vorssaint-dev-update-available
notify "Vorssaint updated" "Pulled $behind commit(s), rebuilt and reinstalled."
