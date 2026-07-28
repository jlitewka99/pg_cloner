#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
metadata_script="$project_dir/scripts/release_metadata.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/pg-cloner-release-metadata.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT INT TERM

fail() {
  print -u2 "release metadata test failed: $1"
  exit 1
}

assert_contains() {
  [[ "$1" == *"$2"* ]] || fail "expected '$2' in: $1"
}

make_repository() {
  local repository="$1"
  mkdir -p "$repository"
  git -C "$repository" init -q -b main
  git -C "$repository" config user.name "PG Cloner tests"
  git -C "$repository" config user.email "tests@example.invalid"
  print "initial" > "$repository/state"
  git -C "$repository" add state
  git -C "$repository" commit -q -m "Initial"
}

metadata() {
  local repository="$1"
  local version="$2"
  local commit="$3"
  (
    cd "$repository"
    zsh "$metadata_script" --version "$version" --commit "$commit"
  )
}

new_repository="$test_root/new"
make_repository "$new_repository"
new_commit="$(git -C "$new_repository" rev-parse HEAD)"
new_output="$(metadata "$new_repository" 1.0.3 "$new_commit")"
assert_contains "$new_output" "should_release=true"
assert_contains "$new_output" "release_reason=new_version"

ancestor_repository="$test_root/ancestor"
make_repository "$ancestor_repository"
ancestor_commit="$(git -C "$ancestor_repository" rev-parse HEAD)"
git -C "$ancestor_repository" tag -a v1.0.3 "$ancestor_commit" -m "PG Cloner 1.0.3"
print "next" > "$ancestor_repository/state"
git -C "$ancestor_repository" add state
git -C "$ancestor_repository" commit -q -m "Next"
head_commit="$(git -C "$ancestor_repository" rev-parse HEAD)"
ancestor_output="$(metadata "$ancestor_repository" 1.0.3 "$head_commit")"
assert_contains "$ancestor_output" "should_release=false"
assert_contains "$ancestor_output" "release_reason=already_released"

resume_repository="$test_root/resume"
make_repository "$resume_repository"
resume_commit="$(git -C "$resume_repository" rev-parse HEAD)"
git -C "$resume_repository" tag -a v1.0.3 "$resume_commit" -m "PG Cloner 1.0.3"
resume_output="$(metadata "$resume_repository" 1.0.3 "$resume_commit")"
assert_contains "$resume_output" "should_release=true"
assert_contains "$resume_output" "release_reason=resume_existing_tag"

conflict_repository="$test_root/conflict"
make_repository "$conflict_repository"
conflict_head="$(git -C "$conflict_repository" rev-parse HEAD)"
conflict_tree="$(git -C "$conflict_repository" write-tree)"
conflict_commit="$(print "Unrelated" | git -C "$conflict_repository" commit-tree "$conflict_tree")"
git -C "$conflict_repository" tag -a v1.0.3 "$conflict_commit" -m "PG Cloner 1.0.3"
if conflict_output="$(metadata "$conflict_repository" 1.0.3 "$conflict_head" 2>&1)"; then
  fail "expected a conflicting tag to fail"
fi
assert_contains "$conflict_output" "does not point to an ancestor"

if invalid_output="$(metadata "$new_repository" 1.0 "$new_commit" 2>&1)"; then
  fail "expected an invalid version to fail"
fi
assert_contains "$invalid_output" "MARKETING_VERSION must use MAJOR.MINOR.PATCH"

print "release metadata tests passed"
