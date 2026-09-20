#!/usr/bin/env bash
set -Eeuo pipefail

readonly project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

expect_usage_error() {
  local name="$1"
  shift
  local stdout_file="$test_root/$name.stdout"
  local stderr_file="$test_root/$name.stderr"
  local status

  set +e
  bash "$@" >"$stdout_file" 2>"$stderr_file"
  status=$?
  set -e

  [[ "$status" == 2 ]] \
    || fail "$name exited $status instead of 2"
  grep -q '^error:' "$stderr_file" \
    || fail "$name did not print an error diagnostic"
  grep -q '^Usage:' "$stderr_file" \
    || fail "$name did not print usage after its diagnostic"
}

expect_help() {
  local name="$1"
  local script="$2"
  local stdout_file="$test_root/$name.help.stdout"
  local stderr_file="$test_root/$name.help.stderr"

  bash "$script" --help >"$stdout_file" 2>"$stderr_file" \
    || fail "$name --help failed"
  grep -q '^Usage:' "$stdout_file" \
    || fail "$name --help did not print usage"
  [[ ! -s "$stderr_file" ]] \
    || fail "$name --help unexpectedly wrote to stderr"
}

readonly -a scripts=(
  judging_assistance.sh
  qualify-archive.sh
  benchmark.sh
  prepare-entry.sh
  build-compressor.sh
  compress-entry.sh
  validate-executable.sh
  host-security-preflight.sh
  install-host-dependencies.sh
  cold-cache-host-helper.sh
)

for script in "${scripts[@]}"; do
  expect_help "$script" "$project_dir/$script"
  expect_usage_error "${script%.sh}-unknown" \
    "$project_dir/$script" --definitely-not-an-option
done

expect_usage_error judging-assistance-missing \
  "$project_dir/judging_assistance.sh"
expect_usage_error prepare-entry-missing \
  "$project_dir/prepare-entry.sh"
expect_usage_error build-compressor-missing \
  "$project_dir/build-compressor.sh"
expect_usage_error compress-entry-missing \
  "$project_dir/compress-entry.sh"
expect_usage_error validate-executable-missing \
  "$project_dir/validate-executable.sh"
expect_usage_error host-security-preflight-missing \
  "$project_dir/host-security-preflight.sh"
expect_usage_error cold-cache-helper-missing \
  "$project_dir/cold-cache-host-helper.sh"
expect_usage_error benchmark-invalid-qualification-os \
  "$project_dir/benchmark.sh" --qualification-os not-in-the-catalog

# Regression for the common qualification invocation that omits the mandatory
# formal-run cache control: the diagnostic must explain how to correct it.
expect_usage_error qualify-archive-cold-cache \
  "$project_dir/qualify-archive.sh" "$project_dir/Entries/Example"
grep -q 'formal enwik9 runs require --cold-cache' \
  "$test_root/qualify-archive-cold-cache.stderr" \
  || fail "qualification diagnostic did not identify --cold-cache"
grep -q '^  --cold-cache ' "$test_root/qualify-archive-cold-cache.stderr" \
  || fail "qualification usage did not describe --cold-cache"

echo "usage feedback tests passed"
