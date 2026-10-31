#!/usr/bin/env bash
set -Eeuo pipefail
readonly project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# Exercise the real host orchestrator and manifest/status parsers. Stub only
# external workers and host setup: no Docker, network, cache eviction, paid
# instances, or execution of entrant scripts is needed for this flow test.
repo="$test_root/repo"
mkdir -p "$repo/lib" "$test_root/bin" "$test_root/entry" "$test_root/work"
cp "$project_dir/judging_assistance.sh" "$project_dir/judging-status.sh" "$repo/"
cp "$project_dir"/lib/*.sh "$repo/lib/"
cat > "$repo/lib/assets.sh" <<'EOF'
hp_tool_assets_ensure() { :; }
hp_example_assets_ensure() { :; }
EOF
cat > "$repo/lib/host-dependencies.sh" <<'EOF'
hp_host_dependencies_ensure() { :; }
EOF
cat > "$repo/lib/cold-cache.sh" <<'EOF'
hp_cold_cache_validate_work_root() { :; }
hp_cold_cache_acquire_lock() { :; }
hp_cold_cache_extract_mincore_helper() { mkdir -p "$(dirname "$2")"; touch "$2"; }
EOF
cat > "$repo/lib/dependency-image.sh" <<'EOF'
hp_dependency_image_build() { printf 'test-build\ttest-runtime\n'; }
EOF
cat > "$test_root/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  info) echo 'test-daemon' ;;
  build|run) : ;;
  image) echo sha256:test-image ;;
  *) exit 99 ;;
esac
EOF
cat > "$repo/worker-stub.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
worker="$(basename "$0")"
printf '%s %s\n' "$worker" "$*" >> "$TEST_WORKER_LOG"
output="" results="" decompressor_output=""
while (( $# )); do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    --decompressor-output) decompressor_output="$2"; shift 2 ;;
    --results) results="$2"; shift 2 ;;
    *) last="$1"; shift ;;
  esac
done
case "$worker" in
  storage-preflight.sh|host-security-preflight.sh) : ;;
  benchmark.sh) echo 8400000 ;;
  prepare-entry.sh)
    mkdir -p "$output"
    cp "$TEST_ENTRY/entry.env" "$output/entry.env"
    printf '#!/bin/sh\nexit 99\n' > "$output/install.sh"
    cp "$output/install.sh" "$output/build.sh"
    printf '%s\n' -e enwik9 archive9 > "$output/comp9.args"
    printf '%s\n' archive9 enwik9_uncompressed > "$output/decomp9.args"
    ;;
  build-compressor.sh)
    mkdir -p "$(dirname "$output")"
    printf '#!/bin/sh\nexit 99\n' > "$output"
    if [[ -n "$decompressor_output" ]]; then
      cp "$output" "$decompressor_output"
    fi
    ;;
  validate-executable.sh)
    mkdir -p "$(dirname "$output")"
    cp "$last" "$output"
    ;;
  compress-entry.sh)
    mkdir -p "$(dirname "$output")" "$results/attempt/compression-entry"
    # Intentionally not a valid archive: any attempt to decompress must fail.
    printf 'generated diagnostic archive\n' > "$output"
    printf 'status=%s\n' "${TEST_COMPRESSION_STATUS:-PASS}" \
      > "$results/attempt/compression-entry/compression.env"
    [[ "${TEST_COMPRESSION_STATUS:-PASS}" == PASS ]] || exit 1
    ;;
  qualify-archive.sh) echo 'UNEXPECTED DECOMPRESSION' >&2; exit 98 ;;
  *) exit 97 ;;
esac
EOF
for worker in storage-preflight.sh host-security-preflight.sh benchmark.sh \
    prepare-entry.sh build-compressor.sh validate-executable.sh \
    compress-entry.sh qualify-archive.sh; do
  cp "$repo/worker-stub.sh" "$repo/$worker"
done
chmod +x "$test_root/bin/docker" "$repo"/*.sh
cat > "$test_root/entry/entry.env" <<'EOF'
ENTRY_FORMAT=self-extracting
EXECUTION_PLATFORM=linux-x86_64
QUALIFICATION_OS=ubuntu-24.04
SOURCE_PACKAGE=source.tar.gz
COMPRESSOR=comp9
COMPRESSOR_FORMAT=executable
COMPRESSOR_ARGUMENTS=comp9.args
ARCHIVE=archive9
ARCHIVE_FORMAT=executable
DECOMPRESSED_OUTPUT=enwik9_uncompressed
EOF
printf 'source placeholder (never executed)\n' > "$test_root/entry/source.tar.gz"
printf 'reference\n' > "$test_root/enwik9"
export TEST_ENTRY="$test_root/entry" PATH="$test_root/bin:$PATH"

run_diagnostic() {
  "$repo/judging_assistance.sh" --compression-only --cold-cache \
    --expected-size 10 --disk-limit-bytes 1000 --work-root "$test_root/work" \
    --results "$test_root/results-$1" "$test_root/entry" "$test_root/enwik9" \
    > "$test_root/$1.stdout" 2> "$test_root/$1.stderr"
}
for mode in absent present url separate; do
  if [[ "$mode" == present ]]; then
    printf 'unused submitted archive\n' > "$test_root/entry/archive9"
  elif [[ "$mode" == url ]]; then
    sed -i 's#^ARCHIVE=archive9$#ARCHIVE=https://example.invalid/archive9#' "$TEST_ENTRY/entry.env"
    printf 'ARCHIVE_SHA256=%064d\n' 0 >> "$TEST_ENTRY/entry.env"
  elif [[ "$mode" == separate ]]; then
    sed -i 's/ENTRY_FORMAT=self-extracting/ENTRY_FORMAT=separate-decompressor/' "$TEST_ENTRY/entry.env"
    sed -i 's/ARCHIVE_FORMAT=executable/ARCHIVE_FORMAT=data/' "$TEST_ENTRY/entry.env"
    printf '%s\n' DECOMPRESSOR=decomp9 DECOMPRESSOR_FORMAT=executable \
      DECOMPRESSOR_ARGUMENTS=decomp9.args >> "$TEST_ENTRY/entry.env"
  fi
  export TEST_WORKER_LOG="$test_root/$mode.workers"
  run_diagnostic "$mode" || { cat "$test_root/$mode.stderr" >&2; fail "$mode diagnostic failed"; }
  final="$(find "$test_root/results-$mode" -name final.env -print -quit)"
  run="$(dirname "$final")"
  grep -qx 'technical_verdict=COMPRESSION_ONLY_PASS' "$final"
  grep -qx 'evaluation_scope=compression_only' "$final"
  grep -qx 'submitted_qualification=skipped_compression_only' "$final"
  grep -qx 'second_decompression=skipped_compression_only' "$final"
  grep -qx 'job_slots=1' "$final"
  [[ -s "$run/generated/archive9" ]] || fail 'generated archive not retained'
  [[ ! -d "$run/submitted-decompression" && ! -d "$run/generated-decompression" ]] \
    || fail 'decompression stage was created'
  ! grep -q '^qualify-archive.sh' "$TEST_WORKER_LOG" || fail 'decompressor was invoked'
  [[ "$(grep -c '^compress-entry.sh' "$TEST_WORKER_LOG")" == 1 ]] || fail 'compressor not invoked exactly once'
  grep -q '^prepare-entry.sh .*--source-only' "$TEST_WORKER_LOG"
  grep -q '^benchmark.sh' "$TEST_WORKER_LOG" || fail 'automatic calibration skipped'
  grep -q '^storage-preflight.sh' "$TEST_WORKER_LOG" || fail 'storage preflight skipped'
  grep -q '^host-security-preflight.sh' "$TEST_WORKER_LOG" || fail 'security preflight skipped'
  grep '^compress-entry.sh' "$TEST_WORKER_LOG" | grep -q -- '--memory-limit-bytes 10737418240'
  grep '^compress-entry.sh' "$TEST_WORKER_LOG" | grep -q -- '--cold-cache'
  grep -q 'not a full qualification' "$run/final-report.txt"
done

# A timed-out compressor must retain its archive and failed diagnostic verdict;
# compression-only must not turn failures into success or invoke decompression.
export TEST_WORKER_LOG="$test_root/late.workers" TEST_COMPRESSION_STATUS=FAIL_TIME
if run_diagnostic late; then fail 'late compression reported success'; fi
final="$(find "$test_root/results-late" -name final.env -print -quit)"
grep -qx 'technical_verdict=FAIL' "$final"
grep -qx 'failed_stage=compression' "$final"
grep -qx 'evaluation_scope=compression_only' "$final"
[[ -s "$(dirname "$final")/generated/archive9" ]] || fail 'late archive lost'
! grep -q '^qualify-archive.sh' "$TEST_WORKER_LOG" || fail 'late archive decompressed'

if "$repo/judging_assistance.sh" --compression-only --jobs 2 \
    "$TEST_ENTRY" "$test_root/enwik9" > /dev/null 2> "$test_root/jobs.stderr"; then
  fail 'compression-only accepted parallel jobs'
fi
grep -q 'no submitted qualification to run in parallel' "$test_root/jobs.stderr"

# --source-only still qualifies its output: it must reach the deliberately
# failing qualifier rather than silently adopt compression-only behavior.
export TEST_WORKER_LOG="$test_root/source-only.workers" TEST_COMPRESSION_STATUS=PASS
if "$repo/judging_assistance.sh" --source-only --expected-size 10 \
    --disk-limit-bytes 1000 --work-root "$test_root/work" \
    --results "$test_root/results-source-only" "$TEST_ENTRY" "$test_root/enwik9" \
    > "$test_root/source-only.stdout" 2> "$test_root/source-only.stderr"; then
  fail 'source-only no longer qualifies its archive'
fi
grep -q '^qualify-archive.sh' "$TEST_WORKER_LOG" || fail 'source-only qualifier skipped'
echo 'compression-only flow tests passed (stubbed workers; no containers or cache eviction)'
