#!/usr/bin/env bash
set -Eeuo pipefail

# Clean, validated merges may advance main; anything needing attention becomes
# a draft PR. Preserve all fork-specific changes in the proposed tree.
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/0x676e67/wreq.git}"
RECONCILIATION_BRANCH="automation/upstream-reconciliation"
SOURCE_CHECKPOINT=".github/upstream-reconciliation/reviewed-source-sha"
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

# A manually merged source-only reconciliation has no Git parent edge to
# upstream: adding that edge would require workflow-write permission. Track
# the precise upstream source snapshot instead; never mistake it for ancestry.
reviewed_source=""
if [[ -f "$SOURCE_CHECKPOINT" ]]; then
  reviewed_source="$(cat "$SOURCE_CHECKPOINT")"
  if ! [[ "$reviewed_source" =~ ^[0-9a-f]{40}$ ]] ||
     ! git merge-base --is-ancestor "$reviewed_source" "$upstream_sha" 2>/dev/null; then
    echo "Invalid or rewritten upstream source checkpoint: $reviewed_source" >&2
    exit 1
  fi
  if [[ "$reviewed_source" == "$upstream_sha" ]]; then
    echo "Already reviewed upstream source $upstream_sha; fork workflows remain independently managed"
    exit 0
  fi
fi

# GitHub's workflow file permission is separate from contents:write and cannot
# be granted to GITHUB_TOKEN. Detect *upstream* workflow edits even when a
# conflict resolution favors the fork and leaves the final tree unchanged.
workflow_base="${reviewed_source:-$(git merge-base "$base_sha" "$upstream_sha" || true)}"
workflow_review_required=false
if [[ -n "$workflow_base" ]] && ! git diff --quiet "$workflow_base" "$upstream_sha" -- .github/workflows; then
  workflow_review_required=true
fi
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

# Repackage a merged upstream tree into a workflow-free fork commit. The bot
# can push that commit using contents:write; the upstream snapshot is recorded
# separately so subsequent runs do not propose already accepted source code.
flatten_upstream_source() {
  mkdir -p .github/upstream-reconciliation
  if [[ "$workflow_review_required" == true ]]; then
    git diff --binary "$workflow_base" "$upstream_sha" -- .github/workflows \
      > .github/upstream-reconciliation/workflow-changes.patch
  fi
  # Restore the entire fork workflow subtree, including deleted/added files.
  git rm -r -f --ignore-unmatch -- .github/workflows
  if [[ -n "$(git ls-tree -r --name-only "$base_sha" -- .github/workflows)" ]]; then
    git restore --source="$base_sha" --staged --worktree -- .github/workflows
  fi
  printf '%s\n' "$upstream_sha" > "$SOURCE_CHECKPOINT"
  git add -A .github/upstream-reconciliation
  git reset --soft "$base_sha"
  git commit -m "Reconcile upstream source $(git rev-parse --short=12 upstream/main) without workflow history" >>"$LOG" 2>&1
}

open_reconciliation_pr() {
  local reason="$1" old_sha
  old_sha="$(git ls-remote origin "refs/heads/$RECONCILIATION_BRANCH" | cut -f1)"
  git switch --force-create "$RECONCILIATION_BRANCH" HEAD

  if [[ "$workflow_review_required" == true || -n "$reviewed_source" ]]; then
    # Workflow-changing upstream commits anywhere in the proposed history can
    # be rejected by GitHub, even when the final tree restores the fork files.
    flatten_upstream_source
  fi

  git push origin "HEAD:refs/heads/$RECONCILIATION_BRANCH" \
    --force-with-lease="refs/heads/$RECONCILIATION_BRANCH:$old_sha"

  {
    printf '%s\n\n' "$marker"
    printf '## Upstream reconciliation required\n\n'
    printf '**Reason:** %s\n\n' "$reason"
    printf -- '- Fork base: %s\n- Upstream: %s (https://github.com/0x676e67/wreq/commit/%s)\n\n' "$base_sha" "$upstream_sha" "$upstream_sha"
    printf 'This is an **unverified** candidate. Resolve conflicts and check feature combinations before merging.\n\n'
    if [[ "$workflow_review_required" == true ]]; then
      printf '### Workflow changes require a separately authorized update\n\n'
      # shellcheck disable=SC2016
      printf 'The scheduled `GITHUB_TOKEN` cannot push changes to `.github/workflows/`. '
      printf 'The original upstream changes are preserved in '
      # shellcheck disable=SC2016
      printf '`.github/upstream-reconciliation/workflow-changes.patch`. '
      printf 'The proposed branch retains the fork workflow files and has no workflow-changing commits. '
      printf '**Review and reconcile the patch with a credential authorized to change workflows** (it may conflict with fork workflow files); validate before accepting the sync. '
      printf 'The draft does not mark upstream history as synchronized.\n\n'
    fi
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
    # Unrelated or rewritten upstream history can fail before Git records any
    # conflicted paths. Open an explicit manual-work PR rather than silently
    # dropping either history or treating the problem as a successful sync.
    git merge --abort >/dev/null 2>&1 || true
    mkdir -p .github/upstream-reconciliation
    {
      printf '# Upstream history requires manual reconciliation\n\n'
      printf 'Fork base: %s\n\nUpstream commit: %s\n\n' "$base_sha" "$upstream_sha"
      printf 'Remove this marker after reconciling histories and passing CI.\n'
    } > .github/upstream-reconciliation/UNMERGEABLE.md
    git add .github/upstream-reconciliation/UNMERGEABLE.md
    git commit -m 'Record upstream history that cannot be merged automatically' >>"$LOG" 2>&1
    open_reconciliation_pr 'Upstream merge failed before creating conflict entries'
    exit 0
  fi
  git merge --abort

  # Include all clean upstream changes, favor fork hunks in tentative result.
  if ! git merge --no-ff --no-edit -X ours upstream/main >>"$LOG" 2>&1; then
    if [[ ! -f "$(git rev-parse --git-path MERGE_HEAD)" ]]; then
      echo "Tentative merge failed without an active merge" >&2
      cat "$LOG" >&2
      exit 1
    fi

    # Git relocates a fork file to PATH~HEAD when the upstream side has a
    # directory at PATH. Restoring only the unmerged placeholder would delete
    # the fork's original file. Remove the colliding upstream subtree first,
    # then put the fork's original PATH back into the candidate tree.
    while IFS= read -r path; do
      if [[ "$path" == *'~HEAD'* ]]; then
        original="${path%%~HEAD*}"
        if [[ -n "$original" ]] && git cat-file -e "HEAD:$original" 2>/dev/null; then
          git rm -r -f --ignore-unmatch -- "$original"
          git rm -f --ignore-unmatch -- "$path"
          git restore --source=HEAD --staged --worktree -- "$original"
        fi
      fi
    done <<< "$conflict_files"

    # -X ours also leaves modify/delete, rename/delete and other unmerged
    # paths. Retain the fork's version of each, including its deletions.
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

# Workflow modifications require a separately authorized review even if the
# non-workflow merge is conflict-free. Do not attempt the forbidden main push.
if [[ "$workflow_review_required" == true ]]; then
  open_reconciliation_pr 'Upstream GitHub Actions workflow changes require authorized review'
  exit 0
fi

# Source-only reconciliations must also flatten later upstream merges: their
# history still includes deferred workflow commits even if this specific update
# contains no new workflow changes.
if [[ -n "$reviewed_source" ]]; then
  flatten_upstream_source
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
