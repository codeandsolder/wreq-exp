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
! git --git-dir="$origin" cat-file -e main:upstream-only.txt 2>/dev/null
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
[[ "$(git --git-dir="$origin" show automation/upstream-reconciliation:conflict.txt)" == fork-conflict ]]
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
! git --git-dir="$origin" cat-file -e automation/upstream-reconciliation:obsolete.txt 2>/dev/null
[[ "$(git --git-dir="$origin" show automation/upstream-reconciliation:upstream-only.txt)" == upstream ]]
echo "PASS delete/modify conflict retains fork deletion"

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
[[ "$(git --git-dir="$origin" show automation/upstream-reconciliation:region)" == 'fork uses file' ]]
[[ "$(git --git-dir="$origin" show automation/upstream-reconciliation:upstream-only.txt)" == upstream ]]
echo "PASS file/directory conflict keeps fork path and unrelated upstream additions"

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
[[ "$(git --git-dir="$origin" show automation/upstream-reconciliation:upstream-only.txt)" == upstream ]]
echo "PASS directory/file conflict retains fork subtree"

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
! git --git-dir="$origin" rev-parse --verify refs/heads/automation/upstream-reconciliation >/dev/null 2>&1
assert_main_has_fork_only
echo "PASS pending reconciliation PR is not overwritten"

setup_case closed
commit_fork_file
commit_upstream_file
candidate="<!-- upstream-sync:base=$(git -C "$work" rev-parse HEAD);upstream=$(git -C "$upstream" rev-parse HEAD) -->"
TEST_CLOSED_PR_BODY="$candidate" run_sync
[[ ! -f "$TEST_PR_BODY" ]]
! git --git-dir="$origin" cat-file -e main:upstream-only.txt 2>/dev/null
echo "PASS closed PR is not recreated for unchanged upstream and main"

setup_case closed_stale
commit_fork_file
commit_upstream_file
TEST_CLOSED_PR_BODY='<!-- upstream-sync:base=old;upstream=old -->' TEST_FAIL_VALIDATE=1 run_sync
assert_draft
echo "PASS new upstream/base fingerprint permits fresh reconciliation"

setup_case pr_denied
commit_fork_file
commit_upstream_file
set +e
TEST_FAIL_VALIDATE=1 TEST_GH_CREATE_FAIL=1 run_sync
ret=$?
set -e
[[ "$ret" -ne 0 ]]
! git --git-dir="$origin" cat-file -e main:upstream-only.txt 2>/dev/null
echo "PASS failed PR creation fails the workflow rather than claiming success"

echo "All upstream-follow Git fixtures passed"
