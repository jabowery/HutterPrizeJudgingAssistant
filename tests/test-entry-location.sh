#!/usr/bin/env bash
set -Eeuo pipefail

readonly project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
source "$project_dir/lib/entry-location.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

hp_entry_location_require_external_or_fixture \
  "$project_dir" "$project_dir/examples/well-formed-entry" \
  || fail "public example fixture was rejected"
hp_entry_location_require_external_or_fixture "$project_dir" "$test_root" \
  || fail "external entry directory was rejected"

set +e
hp_entry_location_require_external_or_fixture \
  "$project_dir" "$project_dir/tests" \
  >"$test_root/internal.stdout" 2>"$test_root/internal.stderr"
status=$?
set -e
[[ "$status" == 2 ]] || fail "internal non-fixture directory was accepted"
grep -q 'must be stored outside' "$test_root/internal.stderr" \
  || fail "internal-directory rejection was not explained"

printf 'fixture\n' > "$test_root/reference"
set +e
"$project_dir/judging_assistance.sh" \
  --serial \
  --expected-size "$(stat --format='%s' "$test_root/reference")" \
  --work-root "$test_root/work" \
  "$project_dir/tests" "$test_root/reference" \
  >"$test_root/orchestrator.stdout" 2>"$test_root/orchestrator.stderr"
orchestrator_status=$?
"$project_dir/prepare-entry.sh" \
  --output "$test_root/prepared" "$project_dir/tests" \
  >"$test_root/prepare.stdout" 2>"$test_root/prepare.stderr"
prepare_status=$?
set -e
[[ "$orchestrator_status" == 2 ]] \
  || fail "orchestrator accepted a repository-internal entry directory"
[[ "$prepare_status" == 2 ]] \
  || fail "preparation accepted a repository-internal entry directory"
grep -q 'must be stored outside' "$test_root/orchestrator.stderr" \
  || fail "orchestrator rejection did not explain the storage boundary"
grep -q 'must be stored outside' "$test_root/prepare.stderr" \
  || fail "preparation rejection did not explain the storage boundary"

grep -q 'hp_entry_location_require_external_or_fixture' \
  "$project_dir/judging_assistance.sh" \
  || fail "main orchestrator does not enforce external entry storage"
grep -q 'hp_entry_location_require_external_or_fixture' \
  "$project_dir/launch-cloud-judging.sh" \
  || fail "cloud launcher does not enforce external entry storage"
grep -q 'hp_entry_location_require_external_or_fixture' \
  "$project_dir/qualify-archive.sh" \
  || fail "qualification wrapper does not enforce external manifest storage"
grep -q 'hp_entry_location_require_external_or_fixture' \
  "$project_dir/prepare-entry.sh" \
  || fail "source-package preparation does not enforce external entry storage"

echo "entry location tests passed"
