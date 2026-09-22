#!/usr/bin/env bash
set -Eeuo pipefail

readonly project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Evaluate the prospective removal of the formerly tracked Entries/ fixture
# without modifying the real index or invoking Git LFS's clean filter.
snapshot_index="$test_root/current-index"
GIT_INDEX_FILE="$snapshot_index" git -C "$project_dir" read-tree HEAD
while IFS= read -r tracked_entry; do
  [[ -n "$tracked_entry" ]] || continue
  GIT_INDEX_FILE="$snapshot_index" git -C "$project_dir" \
    update-index --force-remove -- "$tracked_entry"
done < <(
  GIT_INDEX_FILE="$snapshot_index" git -C "$project_dir" \
    ls-files -- Entries 'Entries/**'
)
[[ -f "$project_dir/examples/well-formed-entry/entry.env" ]] \
  || fail "public fixture is missing from examples/"
GIT_INDEX_FILE="$snapshot_index" \
  "$project_dir/scripts/check-repository-safety.sh" \
    || fail "current repository failed its safety check"

test_repo="$test_root/repository"
mkdir -p -- "$test_repo"
git -C "$test_repo" init -q
git -C "$test_repo" config user.name 'Repository Safety Test'
git -C "$test_repo" config user.email repository-safety@example.invalid
printf '%s\n' \
  '/tmp/' \
  '/Entries/' >"$test_repo/.gitignore"
mkdir -p -- "$test_repo/examples/well-formed-entry"
printf 'public fixture\n' >"$test_repo/examples/well-formed-entry/fixture"
git -C "$test_repo" add .gitignore
git -C "$test_repo" add examples/well-formed-entry/fixture
git -C "$test_repo" commit -qm base
base_oid="$(git -C "$test_repo" rev-parse HEAD)"

mkdir -p -- "$test_repo/tmp"
printf 'confidential\n' >"$test_repo/tmp/entrant-material"
git -C "$test_repo" add -f tmp/entrant-material
git -C "$test_repo" commit -qm 'temporarily add confidential material'
rm -- "$test_repo/tmp/entrant-material"
git -C "$test_repo" add -u
git -C "$test_repo" commit -qm 'remove confidential material'
tip_oid="$(git -C "$test_repo" rev-parse HEAD)"

set +e
printf 'refs/heads/main %s refs/heads/main %s\n' "$tip_oid" "$base_oid" \
  | (
      cd -- "$test_repo"
      "$project_dir/scripts/check-repository-safety.sh" --pre-push origin
    ) \
      >"$test_root/stdout" 2>"$test_root/stderr"
status=$?
set -e

[[ "$status" == 1 ]] \
  || fail "outgoing historical tmp/ content was not rejected"
grep -q 'tmp/entrant-material' "$test_root/stderr" \
  || fail "rejection did not identify the disclosed path"
grep -q 'deleting it in a later commit is insufficient' "$test_root/stderr" \
  || fail "rejection did not explain the historical disclosure"

git -C "$test_repo" switch -qc entrant-history "$base_oid"
mkdir -p -- "$test_repo/Entries/Confidential"
printf 'proprietary\n' >"$test_repo/Entries/Confidential/source"
git -C "$test_repo" add -f Entries/Confidential/source
git -C "$test_repo" commit -qm 'temporarily add contestant material'
rm -- "$test_repo/Entries/Confidential/source"
git -C "$test_repo" add -u
git -C "$test_repo" commit -qm 'remove contestant material'
entrant_tip_oid="$(git -C "$test_repo" rev-parse HEAD)"

set +e
printf 'refs/heads/entrant-history %s refs/heads/entrant-history %s\n' \
  "$entrant_tip_oid" "$base_oid" \
  | (
      cd -- "$test_repo"
      "$project_dir/scripts/check-repository-safety.sh" --pre-push origin
    ) \
      >"$test_root/entry.stdout" 2>"$test_root/entry.stderr"
entry_status=$?
set -e

[[ "$entry_status" == 1 ]] \
  || fail "outgoing historical contestant material was not rejected"
grep -q 'Entries/Confidential/source' "$test_root/entry.stderr" \
  || fail "rejection did not identify the contestant path"
grep -q 'deleting it in a later commit is insufficient' \
  "$test_root/entry.stderr" \
  || fail "contestant rejection did not explain the historical disclosure"

echo "repository safety tests passed"
