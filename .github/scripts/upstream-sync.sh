#!/usr/bin/env bash
set -Eeuo pipefail

# Clean, validated merges may advance main; anything needing attention becomes
# a draft PR. Preserve all fork-specific changes in the proposed tree.
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/0x676e67/wreq.git}"
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

# Never overwrite an open human reconciliation.
existing="$(gh pr list --head "$RECONCILIATION_BRANCH" --base main --state open --json number --jq '.[0].number // empty')"
if [[ -n "$existing" ]]; then
  echo "Reconciliation PR #$existing still open; leaving its branch untouched."
  exit 0
fi

# Closing a reconciliation PR is a human decision. Do not recreate the same
# candidate every six hours; retry automatically only if upstream or main moves.
marker="<!-- upstream-sync:base=$base_sha;upstream=$upstream_sha -->"
closed_bodies="$(gh pr list --head "$RECONCILIATION_BRANCH" --base main --state closed --limit 100 --json body --jq '.[].body')"
if [[ "$closed_bodies" == *"$marker"* ]]; then
  echo "Reconciliation for this fork/upstream pair was closed; not reopening."
  exit 0
fi

open_reconciliation_pr() {
  local reason="$1" old_sha
  old_sha="$(git ls-remote origin "refs/heads/$RECONCILIATION_BRANCH" | cut -f1)"
  git switch --force-create "$RECONCILIATION_BRANCH" HEAD
  git push origin "HEAD:refs/heads/$RECONCILIATION_BRANCH" \
    --force-with-lease="refs/heads/$RECONCILIATION_BRANCH:$old_sha"

  {
    printf '%s\n\n' "$marker"
    printf '## Upstream reconciliation required\n\n'
    printf '**Reason:** %s\n\n' "$reason"
    printf -- '- Fork base: %s\n- Upstream: %s (https://github.com/0x676e67/wreq/commit/%s)\n\n' "$base_sha" "$upstream_sha" "$upstream_sha"
    printf 'This is an **unverified** candidate. Resolve conflicts and check feature combinations before merging.\n\n'
    printf 'This branch will not be overwritten while this draft PR is open.\n\n'
    if [[ -s "$LOG" ]]; then
      printf '### Diagnostics (last 100 lines)\n\n'
      tail -n 100 "$LOG" | sed 's/^/    /'
    fi
  } > "$BODY"
  gh pr create --draft --base main --head "$RECONCILIATION_BRANCH" \
    --title "Reconcile upstream wreq $(git rev-parse --short=12 upstream/main)" \
    --body-file "$BODY"
}

if ! git merge --no-ff --no-edit upstream/main >"$LOG" 2>&1; then
  conflict_files="$(git diff --name-only --diff-filter=U || true)"
  if [[ -z "$conflict_files" ]]; then
    echo "Merge failed without unresolved paths" >&2
    cat "$LOG" >&2
    exit 1
  fi
  git merge --abort

  # Include all clean upstream changes, favor fork hunks in tentative result.
  if ! git merge --no-ff --no-edit -X ours upstream/main >>"$LOG" 2>&1; then
    if [[ ! -f "$(git rev-parse --git-path MERGE_HEAD)" ]]; then
      echo "Tentative merge failed without an active merge" >&2
      cat "$LOG" >&2
      exit 1
    fi

    # -X ours does not handle modify/delete, rename/delete, or D/F conflicts.
    # Retain the fork's version of each still-unmerged path, including deletions.
    while IFS= read -r -d '' path; do
      if git cat-file -e "HEAD:$path" 2>/dev/null; then
        git restore --source=HEAD --staged --worktree -- "$path"
      else
        git rm -f --ignore-unmatch -- "$path"
      fi
    done < <(git diff --name-only --diff-filter=U -z)

    if [[ -n "$(git ls-files -u)" ]]; then
      echo "Unresolved paths remain after favoring fork versions" >&2
      git status --short >&2
      exit 1
    fi
    git commit --no-edit >>"$LOG" 2>&1
  fi
  printf '\nConflicts in original merge (fork changes preferred in candidate):\n%s\n' "$conflict_files" >>"$LOG"
  open_reconciliation_pr "Git merge conflicts"
  exit 0
fi

# GITHUB_TOKEN pushes do not trigger push CI. Validate all targets first and
# retain a time budget to open a draft PR on validation timeout.
if timeout 35m bash -euo pipefail -c '
  cargo +nightly fmt -p wreq -- --check
  cargo +1.99.0 check --locked -p wreq --all-targets --all-features
  cargo +1.99.0 check --locked -p wreq --all-targets --no-default-features --features tokio-rt,webpki-roots
  cargo +1.99.0 clippy --locked -p wreq --all-targets --all-features -- -D warnings
  cargo +1.99.0 test --locked -p wreq --lib
' >"$LOG" 2>&1; then
  if git push origin HEAD:refs/heads/main >>"$LOG" 2>&1; then
    echo "Synced and validated upstream $upstream_sha"
    exit 0
  fi
  printf '\nDirect push to main failed (protection or concurrent update).\n' >>"$LOG"
  open_reconciliation_pr "Validated merge could not be pushed to main"
else
  open_reconciliation_pr "Post-merge formatting, build, lint, test, or timeout failure"
fi
