#!/usr/bin/env bash
set -Eeuo pipefail

readonly project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

"$project_dir/scripts/check-repository-safety.sh" \
  || fail "current repository failed its safety check"

test_repo="$test_root/repository"
mkdir -p -- "$test_repo"
git -C "$test_repo" init -q
git -C "$test_repo" config user.name 'Repository Safety Test'
git -C "$test_repo" config user.email repository-safety@example.invalid
printf '/tmp/\n' >"$test_repo/.gitignore"
git -C "$test_repo" add .gitignore
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

echo "repository safety tests passed"
