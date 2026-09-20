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

expect_usage_error qualify-archive-entry-path \
  "$project_dir/qualify-archive.sh" \
    --preflight-only \
    --expected-size 1 \
    --entry Entries/Wolk/cmix-neif-pre3/ \
    --executable archive9 \
    --output enwik9_decompressed \
    "$project_dir/Entries/Example"
grep -q -- '--entry requires a child name without slashes' \
  "$test_root/qualify-archive-entry-path.stderr" \
  || fail "qualification diagnostic did not distinguish a child name from a path"

manifest_results="$test_root/manifest-results"
bash "$project_dir/qualify-archive.sh" \
  --preflight-only \
  --results "$manifest_results" \
  "$project_dir/Entries/Example" \
  >"$test_root/manifest.stdout" 2>"$test_root/manifest.stderr" \
  || fail "qualification did not accept the entry.env defaults"
manifest_preflight="$(find "$manifest_results" -name preflight.env -type f -print -quit)"
[[ -n "$manifest_preflight" ]] \
  || fail "manifest-driven qualification did not write preflight evidence"
grep -q '^archive_file=archive9$' "$manifest_preflight" \
  || fail "qualification did not use entry.env ARCHIVE"
grep -q '^expected_output=data9$' "$manifest_preflight" \
  || fail "qualification did not use entry.env DECOMPRESSED_OUTPUT"
grep -q '^qualification_os=ubuntu-22.04$' "$manifest_preflight" \
  || fail "qualification did not use entry.env QUALIFICATION_OS"
grep -q '^entry_format=self-extracting$' "$manifest_preflight" \
  || fail "qualification did not record entry.env ENTRY_FORMAT"

echo "usage feedback tests passed"
