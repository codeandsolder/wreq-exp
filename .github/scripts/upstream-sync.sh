#!/usr/bin/env bash
set -Eeuo pipefail

# A clean, tested upstream merge advances main. Conflicts and failed validation
# are deliberately NOT merged: they open one draft PR with an attempted merge.
UPSTREAM_URL="https://github.com/0x676e67/wreq.git"
RECONCILIATION_BRANCH="automation/upstream-reconciliation"
LOG="${RUNNER_TEMP:-/tmp}/wreq-upstream-sync.log"
BODY="${RUNNER_TEMP:-/tmp}/wreq-upstream-reconciliation.md"

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git remote add upstream "$UPSTREAM_URL"
git fetch --no-tags origin main
git fetch --no-tags upstream main
git switch --force-create upstream-sync origin/main

base_sha="$(git rev-parse origin/main)"
upstream_sha="$(git rev-parse upstream/main)"

if git merge-base --is-ancestor upstream/main HEAD; then
  echo "Already contains upstream $upstream_sha"
  exit 0
fi

# Never overwrite a pending human reconciliation, even if upstream moves again.
existing="$(gh pr list --head "$RECONCILIATION_BRANCH" --base main --state open --json number --jq '.[0].number // empty')"
if [[ -n "$existing" ]]; then
  echo "Reconciliation PR #$existing still open; leaving its branch untouched."
  exit 0
fi

open_reconciliation_pr() {
  local reason="$1"
  local old_sha
  old_sha="$(git ls-remote origin "refs/heads/$RECONCILIATION_BRANCH" | cut -f1)"
  git switch --force-create "$RECONCILIATION_BRANCH" HEAD
  # Use a lease even when reusing a previously closed reconciliation branch.
  git push origin "HEAD:refs/heads/$RECONCILIATION_BRANCH" \
    --force-with-lease="refs/heads/$RECONCILIATION_BRANCH:$old_sha"

  {
    printf '## Upstream reconciliation required\n\n'
    printf '**Reason:** %s\n\n' "$reason"
    printf -- '- Fork base: `%s`\n- Upstream: `%s` ([compare](https://github.com/0x676e67/wreq/commit/%s))\n\n' "$base_sha" "$upstream_sha" "$upstream_sha"
    printf 'This is an **unverified** merge candidate and must not be merged without fixing the conflicts/validation failures and passing CI.\n\n'
    printf 'The sync job will not overwrite this branch while its PR remains open.\n\n'
    if [[ -f "$LOG" ]]; then
      printf '### Diagnostic output\n\n```text\n'
      head -n 100 "$LOG"
      printf '\n```\n'
    fi
  } > "$BODY"

  gh pr create --draft --base main --head "$RECONCILIATION_BRANCH" \
    --title "Reconcile upstream wreq $(git rev-parse --short=12 upstream/main)" \
    --body-file "$BODY"
}

if ! git merge --no-ff --no-edit upstream/main >"$LOG" 2>&1; then
  conflict_files="$(git diff --name-only --diff-filter=U || true)"
  printf 'Initial merge conflicted:\n%s\n' "$conflict_files"
  git merge --abort

  # Retain all non-conflicting upstream changes and favor the fork at conflicted
  # hunks, so the draft PR is an actionable starting point, NOT a blind reset.
  if ! git merge --no-ff --no-edit -X ours upstream/main >>"$LOG" 2>&1; then
    git merge --abort 2>/dev/null || true
    # If even the tentative merge fails (e.g. rename/delete), expose upstream
    # as a draft PR. Humans must reconcile the fork-specific changes.
    git reset --hard upstream/main
    printf '\nAutomatic tentative merge failed; draft tracks upstream directly.\n' >>"$LOG"
  fi
  {
    printf '\nConflicting paths from the original merge:\n%s\n' "$conflict_files"
  } >>"$LOG"
  open_reconciliation_pr "Git merge conflicts (tentative merge prefers fork hunks)"
  exit 0
fi

# GitHub-token pushes do not trigger push CI, so validate before advancing main.
if {
  cargo +nightly fmt -p wreq -- --check &&
  cargo +1.99.0 check --locked -p wreq --all-features &&
  cargo +1.99.0 check --locked -p wreq --no-default-features --features tokio-rt,webpki-roots &&
  cargo +1.99.0 clippy --locked -p wreq --lib -- -D warnings &&
  cargo +1.99.0 test --locked -p wreq --lib
} >"$LOG" 2>&1; then
  if git push origin HEAD:refs/heads/main; then
    echo "Synced and validated upstream $upstream_sha"
    exit 0
  fi
  printf '\nDirect push to main failed, perhaps due to protection or concurrent update.\n' >>"$LOG"
  open_reconciliation_pr "Validated merge could not be pushed to main"
else
  open_reconciliation_pr "Post-merge formatting, build, lint or test validation failed"
fi
