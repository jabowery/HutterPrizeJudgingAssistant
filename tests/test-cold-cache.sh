#!/usr/bin/env bash
set -Eeuo pipefail

readonly project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly test_dir="$(mktemp -d)"
trap 'rm -rf -- "$test_dir"' EXIT

command -v cc >/dev/null || {
  echo "error: C compiler is required for the cold-cache verifier test" >&2
  exit 2
}
cc -O2 -Wall -Wextra -Werror \
  "$project_dir/docker/mincore-residency.c" -o "$test_dir/mincore-residency"

dd if=/dev/zero of="$test_dir/resident-file" bs=4096 count=2 status=none
residency_output="$($test_dir/mincore-residency "$test_dir/resident-file")"
grep -q '^page_size_bytes=[1-9][0-9]*$' <<< "$residency_output"
grep -q '^file_bytes=8192$' <<< "$residency_output"
grep -q '^page_count=[1-9][0-9]*$' <<< "$residency_output"
grep -q '^resident_pages=[0-9][0-9]*$' <<< "$residency_output"
grep -q '^resident_file_bytes=[0-9][0-9]*$' <<< "$residency_output"
residency_status="$(awk -F= '/^residency_status=/ {print $2}' \
  <<< "$residency_output")"
set +e
"$test_dir/mincore-residency" --require-zero "$test_dir/resident-file" \
  >/dev/null
require_zero_exit=$?
set -e
case "$residency_status" in
  PASS) (( require_zero_exit == 0 )) ;;
  FAIL) (( require_zero_exit == 1 )) ;;
  *) echo "error: invalid residency status: $residency_status" >&2; exit 1 ;;
esac

assert_formal_rejection() {
  local expected="$1"
  shift
  set +e
  "$@" >"$test_dir/rejection.stdout" 2>"$test_dir/rejection.stderr"
  local status=$?
  set -e
  (( status == 2 ))
  grep -q -- "$expected" "$test_dir/rejection.stderr"
}

assert_formal_rejection 'formal enwik9 runs require --cold-cache' \
  "$project_dir/judging_assistance.sh" --work-root /tmp /missing /missing
assert_formal_rejection 'refuses parallel execution' \
  "$project_dir/judging_assistance.sh" --cold-cache \
    --work-root /tmp /missing /missing
assert_formal_rejection 'formal enwik9 runs require --cold-cache' \
  "$project_dir/qualify-archive.sh" /missing /missing
assert_formal_rejection 'formal enwik9 runs require --cold-cache' \
  "$project_dir/compress-entry.sh" /missing /missing /missing

set +e
(
  source "$project_dir/lib/cold-cache.sh"
  uname() { printf '%s\n' '6.6.87.2-microsoft-standard-WSL2'; }
  findmnt() { printf '%s\n' ext4; }
  hp_cold_cache_validate_work_root /linux-work /mnt/c/enwik9
) >"$test_dir/wsl-storage.stdout" 2>"$test_dir/wsl-storage.stderr"
wsl_storage_exit=$?
set -e
(( wsl_storage_exit == 2 ))
grep -q 'requires enwik9 input on a Linux filesystem' \
  "$test_dir/wsl-storage.stderr"

assert_create_evict_start_order() {
  local path="$1"
  local create_line evict_line start_line
  create_line="$(grep -n 'active_container=.*docker create' "$path" \
    | head -n 1 | cut -d: -f1)"
  evict_line="$(grep -n 'hp_cold_cache_run ' "$path" \
    | tail -n 1 | cut -d: -f1)"
  start_line="$(grep -n 'docker start "\$active_container"' "$path" \
    | head -n 1 | cut -d: -f1)"
  (( create_line < evict_line && evict_line < start_line ))
}

assert_create_evict_start_order "$project_dir/qualify-archive.sh"
assert_create_evict_start_order "$project_dir/compress-entry.sh"
grep -q "printf '3\\\\n' > /proc/sys/vm/drop_caches" \
  "$project_dir/cold-cache-host-helper.sh"
! grep -q 'sudo.*drop_caches' "$project_dir/cold-cache-host-helper.sh"

echo "cold-cache tests passed"
