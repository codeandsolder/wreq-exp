#!/usr/bin/env bash
set -Eeuo pipefail

# Exercise real Git merges and pushes against disposable bare remotes; only
# gh and cargo are mocked. Tests never touch the real repository's branches.
script="$(cd "$(dirname "$0")" && pwd)/upstream-sync.sh"
root="$(mktemp -d "${TMPDIR:-/tmp}/wreq-upstream-sync-test.XXXXXXXX")"
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/bin"
cat > "$root/bin/gh" <<'MOCK_GH'
#!/usr/bin/env bash
set -euo pipefail
case "$1 $2" in
  "pr list")
    echo "LIST" >> "$TEST_GH_CALLS"
    if [[ " $* " == *" --state closed "* ]]; then
      printf '%s\n' "${TEST_CLOSED_PR_BODY:-}"
    else
      printf '%s\n' "${TEST_EXISTING_PR:-}"
    fi
    ;;
  "pr create")
    printf 'CREATE %s\n' "$*" >> "$TEST_GH_CALLS"
    file=""
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == "--body-file" ]]; then
        file="$2"
        break
      fi
      shift
    done
    [[ -n "$file" ]]
    cp "$file" "$TEST_PR_BODY"
    if [[ "${TEST_GH_CREATE_FAIL:-0}" == 1 ]]; then
      echo "GitHub refused PR creation" >&2
      exit 42
    fi
    echo "https://github.invalid/pr/1"
    ;;
  *)
    echo "Unrecognized gh invocation: $*" >&2
    exit 1
    ;;
esac
MOCK_GH
cat > "$root/bin/cargo" <<'MOCK_CARGO'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TEST_CARGO_CALLS"
if [[ "${TEST_FAIL_VALIDATE:-0}" == 1 ]]; then
  echo "Synthetic Rust validation failure" >&2
  exit 42
fi
MOCK_CARGO
chmod +x "$root/bin/gh" "$root/bin/cargo"
export PATH="$root/bin:$PATH"

setup_case() {
  local name="$1"
  local dir="$root/$name"
  mkdir -p "$dir"
  git init --quiet --bare --initial-branch=main "$dir/origin.git"
  git init --quiet --bare --initial-branch=main "$dir/upstream.git"
  git init --quiet --initial-branch=main "$dir/seed"
  git -C "$dir/seed" config user.name "sync-test"
  git -C "$dir/seed" config user.email "test@example.invalid"
  printf 'base\n' > "$dir/seed/conflict.txt"
  printf 'base\n' > "$dir/seed/obsolete.txt"
  git -C "$dir/seed" add .
  git -C "$dir/seed" commit --quiet -m base
  git -C "$dir/seed" push --quiet "$dir/origin.git" HEAD:main
  git -C "$dir/seed" push --quiet "$dir/upstream.git" HEAD:main
  git clone --quiet --branch main "$dir/origin.git" "$dir/work"
  git clone --quiet --branch main "$dir/upstream.git" "$dir/upwork"
  for repo in work upwork; do
    git -C "$dir/$repo" config user.name sync-test
    git -C "$dir/$repo" config user.email test@example.invalid
  done
  export UPSTREAM_URL="$dir/upstream.git"
  export RUNNER_TEMP="$dir"
  export TEST_GH_CALLS="$dir/gh.calls"
  export TEST_CARGO_CALLS="$dir/cargo.calls"
  export TEST_PR_BODY="$dir/pr.body"
  export TEST_EXISTING_PR=""
  export TEST_CLOSED_PR_BODY=""
  export TEST_FAIL_VALIDATE=0
  export TEST_GH_CREATE_FAIL=0
  work="$dir/work"
  upstream="$dir/upwork"
  origin="$dir/origin.git"
}

commit_fork_file() {
  echo fork > "$work/fork-only.txt"
  git -C "$work" add .
  git -C "$work" commit --quiet -m "fork feature"
  git -C "$work" push --quiet origin main
}

commit_upstream_file() {
  echo upstream > "$upstream/upstream-only.txt"
  git -C "$upstream" add .
  git -C "$upstream" commit --quiet -m "upstream feature"
  git -C "$upstream" push --quiet origin main
}

run_sync() {
  (cd "$work" && bash "$script") > "$RUNNER_TEMP/output.log" 2>&1 || {
    cat "$RUNNER_TEMP/output.log" >&2
    return 1
  }
}

assert_main_has_fork_only() {
  [[ "$(git --git-dir="$origin" show main:fork-only.txt)" == fork ]]
}

assert_draft() {
  [[ "$(cat "$TEST_GH_CALLS")" == *" --draft"* ]]
  [[ -f "$TEST_PR_BODY" ]]
  git --git-dir="$origin" rev-parse --verify refs/heads/automation/upstream-reconciliation >/dev/null
}

# A negated command at top level does not honor set -e. Assert explicitly so
# a regression cannot silently pass the fixture and continue to the next one.
assert_blob_absent() {
  if git --git-dir="$origin" cat-file -e "$1" 2>/dev/null; then
    echo "Unexpected object in origin: $1" >&2
    return 1
  fi
}

assert_ref_absent() {
  if git --git-dir="$origin" rev-parse --verify "$1" >/dev/null 2>&1; then
    echo "Unexpected reference in origin: $1" >&2
    return 1
  fi
}

setup_case noop
commit_fork_file
run_sync
assert_main_has_fork_only
[[ ! -f "$TEST_GH_CALLS" ]]
echo "PASS noop when fork already contains upstream"

setup_case clean
commit_fork_file
commit_upstream_file
run_sync
assert_main_has_fork_only
[[ "$(git --git-dir="$origin" show main:upstream-only.txt)" == upstream ]]
[[ ! -f "$TEST_PR_BODY" ]]
[[ "$(wc -l < "$TEST_CARGO_CALLS")" -eq 5 ]]
echo "PASS clean merge with validation advances main"

setup_case validation
commit_fork_file
commit_upstream_file
TEST_FAIL_VALIDATE=1 run_sync
assert_main_has_fork_only
assert_blob_absent main:upstream-only.txt
assert_draft
[[ "$(git --git-dir="$origin" show automation/upstream-reconciliation:upstream-only.txt)" == upstream ]]
[[ "$(cat "$TEST_PR_BODY")" == *"Synthetic Rust validation failure"* ]]
echo "PASS validation failure opens draft and keeps main unchanged"

setup_case conflict
commit_fork_file
echo fork-conflict > "$work/conflict.txt"
git -C "$work" add .
git -C "$work" commit --quiet -m "fork edits shared file"
git -C "$work" push --quiet origin main
commit_upstream_file
echo upstream-conflict > "$upstream/conflict.txt"
git -C "$upstream" add .
git -C "$upstream" commit --quiet -m "upstream edits shared file"
git -C "$upstream" push --quiet origin main
run_sync
assert_draft
assert_main_has_fork_only
conflicted="$(git --git-dir="$origin" show automation/upstream-reconciliation:conflict.txt)"
[[ "$conflicted" == *'<<<<<<<'* ]]
[[ "$conflicted" == *'fork-conflict'* ]]
[[ "$conflicted" == *'upstream-conflict'* ]]
[[ "$(git --git-dir="$origin" show automation/upstream-reconciliation:upstream-only.txt)" == upstream ]]
[[ "$(cat "$TEST_PR_BODY")" == *"conflict.txt"* ]]
echo "PASS content conflict creates draft retaining fork and non-conflicting upstream changes"

setup_case modify_delete
commit_fork_file
echo fork-edited > "$work/obsolete.txt"
git -C "$work" add .
git -C "$work" commit --quiet -m "fork modifies obsolete"
git -C "$work" push --quiet origin main
commit_upstream_file
git -C "$upstream" rm --quiet obsolete.txt
git -C "$upstream" commit --quiet -m "upstream removes obsolete"
git -C "$upstream" push --quiet origin main
run_sync
assert_draft
[[ "$(git --git-dir="$origin" show automation/upstream-reconciliation:obsolete.txt)" == fork-edited ]]
[[ "$(git --git-dir="$origin" show automation/upstream-reconciliation:upstream-only.txt)" == upstream ]]
echo "PASS modify/delete conflict retains fork file without dropping upstream changes"

setup_case delete_modify
commit_fork_file
git -C "$work" rm --quiet obsolete.txt
git -C "$work" commit --quiet -m "fork removes obsolete"
git -C "$work" push --quiet origin main
commit_upstream_file
echo upstream-edited > "$upstream/obsolete.txt"
git -C "$upstream" add .
git -C "$upstream" commit --quiet -m "upstream modifies obsolete"
git -C "$upstream" push --quiet origin main
run_sync
assert_draft
assert_blob_absent main:obsolete.txt
[[ "$(git --git-dir="$origin" show automation/upstream-reconciliation:obsolete.txt)" == upstream-edited ]]
[[ "$(git --git-dir="$origin" show automation/upstream-reconciliation:upstream-only.txt)" == upstream ]]
echo "PASS delete/modify conflict preserves upstream change for manual resolution"

setup_case file_directory
commit_fork_file
printf 'fork uses file\n' > "$work/region"
git -C "$work" add .
git -C "$work" commit --quiet -m 'fork adds file at path'
git -C "$work" push --quiet origin main
commit_upstream_file
mkdir -p "$upstream/region"
printf 'upstream uses directory\n' > "$upstream/region/child.txt"
git -C "$upstream" add .
git -C "$upstream" commit --quiet -m 'upstream adds directory at path'
git -C "$upstream" push --quiet origin main
run_sync
assert_draft
fork_file="$(git --git-dir="$origin" ls-tree -r --name-only automation/upstream-reconciliation | rg '^region~' | head -n 1)"
[[ -n "$fork_file" ]]
[[ "$(git --git-dir="$origin" show "automation/upstream-reconciliation:$fork_file")" == 'fork uses file' ]]
[[ "$(git --git-dir="$origin" show automation/upstream-reconciliation:region/child.txt)" == 'upstream uses directory' ]]
[[ "$(git --git-dir="$origin" show automation/upstream-reconciliation:upstream-only.txt)" == upstream ]]
echo "PASS file/directory conflict retains both versions as distinct paths for resolution"

setup_case directory_file
commit_fork_file
mkdir -p "$work/region"
printf 'fork uses directory\n' > "$work/region/child.txt"
git -C "$work" add .
git -C "$work" commit --quiet -m 'fork adds directory at path'
git -C "$work" push --quiet origin main
commit_upstream_file
printf 'upstream uses file\n' > "$upstream/region"
git -C "$upstream" add .
git -C "$upstream" commit --quiet -m 'upstream adds file at path'
git -C "$upstream" push --quiet origin main
run_sync
assert_draft
[[ "$(git --git-dir="$origin" show automation/upstream-reconciliation:region/child.txt)" == 'fork uses directory' ]]
upstream_file="$(git --git-dir="$origin" ls-tree -r --name-only automation/upstream-reconciliation | rg '^region~' | head -n 1)"
[[ -n "$upstream_file" ]]
[[ "$(git --git-dir="$origin" show "automation/upstream-reconciliation:$upstream_file")" == 'upstream uses file' ]]
[[ "$(git --git-dir="$origin" show automation/upstream-reconciliation:upstream-only.txt)" == upstream ]]
echo "PASS directory/file conflict preserves both versions for resolution"

setup_case unrelated
commit_fork_file
git -C "$upstream" checkout --quiet --orphan unrelated
git -C "$upstream" rm -qrf .
echo different-history > "$upstream/other-project.txt"
git -C "$upstream" add .
git -C "$upstream" commit --quiet -m 'unrelated upstream history'
git -C "$upstream" push --quiet --force origin HEAD:main
run_sync
assert_draft
assert_main_has_fork_only
[[ "$(git --git-dir="$origin" show automation/upstream-reconciliation:.github/upstream-reconciliation/UNMERGEABLE.md)" == *'manual reconciliation'* ]]
[[ "$(git --git-dir="$origin" show automation/upstream-reconciliation:fork-only.txt)" == fork ]]
echo "PASS unrelated upstream history creates actionable draft without deleting fork"

setup_case pending
commit_fork_file
commit_upstream_file
TEST_EXISTING_PR=99 run_sync
[[ ! -f "$TEST_CARGO_CALLS" ]]
[[ ! -f "$TEST_PR_BODY" ]]
assert_ref_absent refs/heads/automation/upstream-reconciliation
assert_main_has_fork_only
echo "PASS pending reconciliation PR is not overwritten"

setup_case closed
commit_fork_file
commit_upstream_file
candidate="<!-- upstream-sync:base=$(git -C "$work" rev-parse HEAD);upstream=$(git -C "$upstream" rev-parse HEAD) -->"
TEST_CLOSED_PR_BODY="$candidate" run_sync
[[ ! -f "$TEST_PR_BODY" ]]
assert_blob_absent main:upstream-only.txt
echo "PASS closed PR is not recreated for unchanged upstream and main"

setup_case closed_stale
commit_fork_file
commit_upstream_file
TEST_CLOSED_PR_BODY='<!-- upstream-sync:base=old;upstream=old -->' TEST_FAIL_VALIDATE=1 run_sync
assert_draft
echo "PASS new upstream/base fingerprint permits fresh reconciliation"

# Simulate GitHub's refusal of newly pushed commits touching workflows,
# including changes hidden by a later restoring commit.
install_workflow_push_guard() {
  cat > "$origin/hooks/pre-receive" <<'WORKFLOW_GUARD'
#!/usr/bin/env bash
set -euo pipefail
while read -r old new ref; do
  [[ "$ref" == refs/heads/automation/upstream-reconciliation ]] || continue
  while read -r commit; do
    if [[ -n "$(git diff-tree --no-commit-id --name-only -r "$commit" -- .github/workflows)" ]]; then
      echo "reject workflow-changing commit: $commit" >&2
      exit 1
    fi
  done < <(git rev-list "$new" --not refs/heads/main)
done
WORKFLOW_GUARD
  chmod +x "$origin/hooks/pre-receive"
}

setup_case new_workflow
commit_fork_file
commit_upstream_file
mkdir -p "$upstream/.github/workflows"
printf 'name: Upstream CI\n' > "$upstream/.github/workflows/ci.yml"
git -C "$upstream" add .github/workflows
git -C "$upstream" commit --quiet -m 'upstream adds workflow'
git -C "$upstream" push --quiet origin main
install_workflow_push_guard
run_sync
assert_draft
assert_blob_absent automation/upstream-reconciliation:.github/workflows/ci.yml
[[ "$(git --git-dir="$origin" show automation/upstream-reconciliation:upstream-only.txt)" == upstream ]]
[[ "$(git --git-dir="$origin" show automation/upstream-reconciliation:.github/upstream-reconciliation/workflow-changes.patch)" == *'name: Upstream CI'* ]]
[[ "$(cat "$TEST_PR_BODY")" == *'authorized to change workflows'* ]]
assert_blob_absent main:upstream-only.txt
[[ "$(git --git-dir="$origin" show automation/upstream-reconciliation:.github/upstream-reconciliation/reviewed-source-sha)" == "$(git -C "$upstream" rev-parse HEAD)" ]]
echo "PASS workflow-adding upstream becomes pushable draft with full patch and unchanged main"

setup_case conflicting_workflow
commit_fork_file
mkdir -p "$work/.github/workflows" "$upstream/.github/workflows"
printf 'name: Fork CI\n' > "$work/.github/workflows/ci.yml"
git -C "$work" add .github/workflows
git -C "$work" commit --quiet -m 'fork adds workflow'
git -C "$work" push --quiet origin main
commit_upstream_file
printf 'name: Upstream CI\n' > "$upstream/.github/workflows/ci.yml"
git -C "$upstream" add .github/workflows
git -C "$upstream" commit --quiet -m 'upstream adds conflicting workflow'
git -C "$upstream" push --quiet origin main
install_workflow_push_guard
run_sync
assert_draft
[[ "$(git --git-dir="$origin" show automation/upstream-reconciliation:.github/workflows/ci.yml)" == 'name: Fork CI' ]]
[[ "$(git --git-dir="$origin" show automation/upstream-reconciliation:upstream-only.txt)" == upstream ]]
[[ "$(git --git-dir="$origin" show automation/upstream-reconciliation:.github/upstream-reconciliation/workflow-changes.patch)" == *'name: Upstream CI'* ]]
[[ "$(cat "$TEST_PR_BODY")" == *'Upstream source conflicts'* ]]
echo "PASS workflow conflict retains fork workflow and upstream patch without blocked commit history"

source_checkpoint() {
  mkdir -p "$work/.github/upstream-reconciliation"
  git -C "$upstream" rev-parse HEAD > "$work/.github/upstream-reconciliation/reviewed-source-sha"
  git -C "$work" add .github/upstream-reconciliation/reviewed-source-sha
  git -C "$work" commit --quiet -m 'review upstream source snapshot'
  git -C "$work" push --quiet origin main
}

setup_case checkpoint_noop
commit_fork_file
commit_upstream_file
source_checkpoint
original_main="$(git --git-dir="$origin" rev-parse main)"
run_sync
[[ "$(git --git-dir="$origin" rev-parse main)" == "$original_main" ]]
[[ ! -f "$TEST_GH_CALLS" ]]
echo "PASS accepted upstream source checkpoint prevents duplicate reconciliation"

setup_case checkpoint_invalid
commit_fork_file
commit_upstream_file
mkdir -p "$work/.github/upstream-reconciliation"
printf '%040d\n' 0 > "$work/.github/upstream-reconciliation/reviewed-source-sha"
git -C "$work" add .github/upstream-reconciliation/reviewed-source-sha
git -C "$work" commit --quiet -m 'invalid upstream source checkpoint'
git -C "$work" push --quiet origin main
if run_sync; then
  echo 'Expected invalid source checkpoint to block synchronization' >&2
  exit 1
fi
[[ "$(cat "$RUNNER_TEMP/output.log")" == *'Invalid or rewritten upstream source checkpoint'* ]]
[[ ! -f "$TEST_GH_CALLS" ]]
echo "PASS invalid source checkpoint rejects unrelated or rewritten upstream history"

setup_case checkpoint_incremental
commit_fork_file
commit_upstream_file
mkdir -p "$upstream/.github/workflows"
printf 'name: Original CI\n' > "$upstream/.github/workflows/ci.yml"
git -C "$upstream" add .github/workflows
git -C "$upstream" commit --quiet -m 'original upstream workflow'
git -C "$upstream" push --quiet origin main
# Simulate a reviewed source-only merge retaining the fork's workflow tree.
git -C "$work" show HEAD:fork-only.txt > /dev/null
git -C "$upstream" show HEAD:upstream-only.txt > "$work/upstream-only.txt"
git -C "$work" add upstream-only.txt
git -C "$work" commit --quiet -m 'accept upstream source only'
source_checkpoint
printf 'new upstream source\n' > "$upstream/new-feature.txt"
git -C "$upstream" add new-feature.txt
git -C "$upstream" commit --quiet -m 'upstream feature after accepted workflow divergence'
git -C "$upstream" push --quiet origin main
install_workflow_push_guard
run_sync
assert_main_has_fork_only
[[ "$(git --git-dir="$origin" show main:new-feature.txt)" == 'new upstream source' ]]
[[ "$(git --git-dir="$origin" show main:.github/upstream-reconciliation/reviewed-source-sha)" == "$(git -C "$upstream" rev-parse HEAD)" ]]
assert_blob_absent main:.github/workflows/ci.yml
[[ ! -f "$TEST_PR_BODY" ]]
[[ "$(wc -l < "$TEST_CARGO_CALLS")" -eq 5 ]]
echo "PASS subsequent upstream source auto-syncs without workflow-write permission"

setup_case checkpoint_true_content_conflict
commit_fork_file
commit_upstream_file
source_checkpoint
printf 'fork-specific edit\n' > "$work/conflict.txt"
git -C "$work" add conflict.txt
git -C "$work" commit --quiet -m 'fork edit after source checkpoint'
git -C "$work" push --quiet origin main
printf 'upstream-specific edit\n' > "$upstream/conflict.txt"
git -C "$upstream" add conflict.txt
git -C "$upstream" commit --quiet -m 'upstream edit after source checkpoint'
git -C "$upstream" push --quiet origin main
run_sync
assert_draft
conflicted="$(git --git-dir="$origin" show automation/upstream-reconciliation:conflict.txt)"
[[ "$conflicted" == *'<<<<<<<'* ]]
[[ "$conflicted" == *'fork-specific edit'* ]]
[[ "$conflicted" == *'upstream-specific edit'* ]]
[[ "$(git --git-dir="$origin" show main:conflict.txt)" == 'fork-specific edit' ]]
[[ "$(git --git-dir="$origin" show automation/upstream-reconciliation:.github/upstream-reconciliation/reviewed-source-sha)" == "$(git -C "$upstream" rev-parse HEAD)" ]]
echo "PASS true post-checkpoint content conflicts preserve both sides in a draft"

setup_case checkpoint_add_add_conflict
commit_fork_file
commit_upstream_file
source_checkpoint
mkdir -p "$work/tests/support" "$upstream/tests/support"
printf 'fork test helper\n' > "$work/tests/support/tls_cert.rs"
git -C "$work" add tests/support/tls_cert.rs
git -C "$work" commit --quiet -m 'fork adds helper'
git -C "$work" push --quiet origin main
printf 'upstream test helper\n' > "$upstream/tests/support/tls_cert.rs"
git -C "$upstream" add tests/support/tls_cert.rs
git -C "$upstream" commit --quiet -m 'upstream adds same helper path'
git -C "$upstream" push --quiet origin main
run_sync
assert_draft
conflicted="$(git --git-dir="$origin" show automation/upstream-reconciliation:tests/support/tls_cert.rs)"
[[ "$conflicted" == *'<<<<<<<'* ]]
[[ "$conflicted" == *'fork test helper'* ]]
[[ "$conflicted" == *'upstream test helper'* ]]
[[ "$(git --git-dir="$origin" show main:tests/support/tls_cert.rs)" == 'fork test helper' ]]
echo "PASS independent test helper additions preserve both implementations"

setup_case checkpoint_validation_failure
commit_fork_file
commit_upstream_file
source_checkpoint
old_sha="$(git --git-dir="$origin" show main:.github/upstream-reconciliation/reviewed-source-sha)"
printf 'later upstream update\n' > "$upstream/later.txt"
git -C "$upstream" add later.txt
git -C "$upstream" commit --quiet -m 'new update requires compilation'
git -C "$upstream" push --quiet origin main
TEST_FAIL_VALIDATE=1 run_sync
assert_draft
[[ "$(git --git-dir="$origin" show main:.github/upstream-reconciliation/reviewed-source-sha)" == "$old_sha" ]]
[[ "$(git --git-dir="$origin" show automation/upstream-reconciliation:later.txt)" == 'later upstream update' ]]
[[ "$(git --git-dir="$origin" show automation/upstream-reconciliation:.github/upstream-reconciliation/reviewed-source-sha)" == "$(git -C "$upstream" rev-parse HEAD)" ]]
echo "PASS failed incremental validation keeps main unchanged and publishes checkpointed draft"

setup_case checkpoint_workflow_update
commit_fork_file
commit_upstream_file
source_checkpoint
mkdir -p "$upstream/.github/workflows"
printf 'name: New upstream CI\n' > "$upstream/.github/workflows/ci.yml"
git -C "$upstream" add .github/workflows
git -C "$upstream" commit --quiet -m 'later upstream workflow change'
git -C "$upstream" push --quiet origin main
install_workflow_push_guard
run_sync
assert_draft
assert_blob_absent automation/upstream-reconciliation:.github/workflows/ci.yml
[[ "$(git --git-dir="$origin" show automation/upstream-reconciliation:.github/upstream-reconciliation/reviewed-source-sha)" == "$(git -C "$upstream" rev-parse HEAD)" ]]
[[ "$(git --git-dir="$origin" show automation/upstream-reconciliation:.github/upstream-reconciliation/workflow-changes.patch)" == *'name: New upstream CI'* ]]
echo "PASS later upstream workflow updates require a new explicit review"

setup_case pr_denied
commit_fork_file
commit_upstream_file
set +e
TEST_FAIL_VALIDATE=1 TEST_GH_CREATE_FAIL=1 run_sync
ret=$?
set -e
[[ "$ret" -ne 0 ]]
assert_blob_absent main:upstream-only.txt
echo "PASS failed PR creation fails the workflow rather than claiming success"

echo "All upstream-follow Git fixtures passed"
