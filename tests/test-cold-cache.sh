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

assert_formal_rejection 'formal cache control requires serial execution' \
  "$project_dir/judging_assistance.sh" --jobs 2 /missing /missing
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

# The executables that source this library intentionally define a global,
# readonly script_dir. Library functions must not try to shadow it with a
# local variable, which Bash rejects before performing the cache operation.
set +e
(
  readonly script_dir="$project_dir"
  source "$project_dir/lib/cold-cache.sh"
  unset HP_COLD_CACHE_LOCK_HELD HP_COLD_CACHE_LOCK_FD
  sudo() { return 2; }
  hp_cold_cache_acquire_lock /definitely-missing
) >"$test_dir/readonly-lock.stdout" 2>"$test_dir/readonly-lock.stderr"
readonly_lock_exit=$?
(
  readonly script_dir="$project_dir"
  source "$project_dir/lib/cold-cache.sh"
  unset HP_COLD_CACHE_LOCK_HELD HP_COLD_CACHE_LOCK_FD
  hp_cold_cache_run "$project_dir" /missing-helper /missing-target \
    "$test_dir/missing-evidence" 0 missing test
) >"$test_dir/readonly-run.stdout" 2>"$test_dir/readonly-run.stderr"
readonly_run_exit=$?
set -e
(( readonly_lock_exit != 0 ))
(( readonly_run_exit == 2 ))
! grep -q 'readonly variable' "$test_dir/readonly-lock.stderr"
! grep -q 'readonly variable' "$test_dir/readonly-run.stderr"

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
docker_access_line="$(grep -n '^require_docker_daemon$' \
  "$project_dir/judging_assistance.sh" | cut -d: -f1)"
cold_lock_line="$(grep -n '^[[:space:]]*hp_cold_cache_acquire_lock ' \
  "$project_dir/judging_assistance.sh" | cut -d: -f1)"
(( docker_access_line < cold_lock_line ))
grep -q "printf '3\\\\n' > /proc/sys/vm/drop_caches" \
  "$project_dir/cold-cache-host-helper.sh"
! grep -q 'sudo.*drop_caches' "$project_dir/cold-cache-host-helper.sh"

echo "cold-cache tests passed"
