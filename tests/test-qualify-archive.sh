#!/usr/bin/env bash
set -Eeuo pipefail

readonly project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly test_dir="$(mktemp -d)"
trap 'rm -rf -- "$test_dir"' EXIT

mkdir -p \
  "$test_dir/Entries/Good" \
  "$test_dir/Entries/Fork" \
  "$test_dir/Entries/Bad" \
  "$test_dir/Entries/Nested" \
  "$test_dir/Entries/ProcessTree" \
  "$test_dir/Entries/Memory" \
  "$test_dir/Entries/AggregateMemory" \
  "$test_dir/Entries/CpuLimit" \
  "$test_dir/work"
printf 'small judging fixture\n' > "$test_dir/enwik9"

cat > "$test_dir/Entries/Good/archive9" <<'EOF'
#!/bin/sh
set -eu
test -r archive9
test ! -e /reference/enwik9
test ! -e /usr/bin
test ! -e /bin/gzip
test ! -e /bin/bsdtar
test ! -e /proc/self/status
test -L /proc/self/exe
test -r /proc/self/exe
test ! -e /proc/1/root
printf 'small judging fixture\n' > data9
EOF

cat > "$test_dir/Entries/Fork/archive9" <<'EOF'
#!/bin/sh
set -eu
(printf 'small judging fixture\n' > data9) &
wait
EOF

cat > "$test_dir/Entries/Bad/archive9" <<'EOF'
#!/bin/sh
printf 'SMALL JUDGING FIXTURE\n' > data9
EOF

cat > "$test_dir/Entries/Nested/archive9" <<'EOF'
#!/bin/sh
if [ "${1:-}" = child ]; then
  exit 0
fi
./archive9 child
printf 'small judging fixture\n' > data9
EOF

cat > "$test_dir/Entries/ProcessTree/archive9" <<'EOF'
#!/bin/sh
if [ "${1:-}" = child ]; then
  printf 'small judging fixture\n' > data9
  exit 0
fi
exec ./archive9 child
EOF

cat > "$test_dir/Entries/CpuLimit/archive9" <<'EOF'
#!/bin/sh
set -eu
i=0
while [ "$i" -lt 3000000 ]; do
  i=$((i + 1))
done
printf 'small judging fixture\n' > data9
EOF

cat > "$test_dir/Entries/Memory/archive9" <<'EOF'
#!/bin/sh
set -eu
allocation=x
i=0
while [ "$i" -lt 24 ]; do
  allocation=$allocation$allocation
  i=$((i + 1))
done
printf 'small judging fixture\n' > data9
EOF

cat > "$test_dir/Entries/AggregateMemory/archive9" <<'EOF'
#!/bin/sh
allocate_forever() {
  allocation=x
  i=0
  while [ "$i" -lt 22 ]; do
    allocation=$allocation$allocation
    i=$((i + 1))
  done
  while :; do :; done
}
allocate_forever &
allocate_forever &
wait
EOF

chmod 0555 \
  "$test_dir/Entries/Good/archive9" \
  "$test_dir/Entries/Fork/archive9" \
  "$test_dir/Entries/Bad/archive9" \
  "$test_dir/Entries/Nested/archive9" \
  "$test_dir/Entries/ProcessTree/archive9" \
  "$test_dir/Entries/Memory/archive9" \
  "$test_dir/Entries/AggregateMemory/archive9" \
  "$test_dir/Entries/CpuLimit/archive9"
readonly fixture_size="$(stat --format='%s' "$test_dir/enwik9")"

set +e
"$project_dir/qualify-archive.sh" \
  --executable archive9 \
  --output data9 \
  --entry Good \
  --expected-size "$fixture_size" \
  --time-limit-seconds 30 \
  --memory-limit-bytes 134217728 \
  --disk-limit-bytes 104857600 \
  --disk-poll-seconds 1 \
  --work-root "$test_dir/work" \
  --results "$test_dir/good-results" \
  "$test_dir/Entries" "$test_dir/enwik9"
good_exit=$?
set -e

if (( good_exit != 0 )); then
  find "$test_dir/good-results" -type f \
    \( -name stderr.log -o -name container.log -o -name time.txt \) \
    -print -exec sed -n '1,160p' {} \;
  exit "$good_exit"
fi

good_summary="$(find "$test_dir/good-results" -name summary.tsv -type f -print -quit)"
grep -q $'^Good\tPASS\t' "$good_summary"
good_report="$(find "$test_dir/good-results" -name report.txt -type f -print -quit)"
grep -q '^Time limit: 00:00:30 (explicit override; no Geekbench score)$' "$good_report"
grep -q '^Memory peak-RSS limit: 0.125 GiB$' "$good_report"
grep -q '^Execution-environment RAM: 16 GiB$' "$good_report"
grep -q '^Disk limit: 0.1048576 GB allocated (sampled every 00:00:01)$' "$good_report"
good_inspect="$(find "$test_dir/good-results" \
  -name container-inspect.json -type f -print -quit)"
grep -q '"Memory": 17179869184' "$good_inspect"
grep -q '"MemorySwap": 17179869184' "$good_inspect"

set +e
"$project_dir/qualify-archive.sh" \
  --skip-build \
  --executable archive9 \
  --output data9 \
  --entry Fork \
  --expected-size "$fixture_size" \
  --time-limit-seconds 30 \
  --memory-limit-bytes 134217728 \
  --disk-limit-bytes 104857600 \
  --disk-poll-seconds 1 \
  --results "$test_dir/fork-results" \
  "$test_dir/Entries" "$test_dir/enwik9"
fork_exit=$?
set -e
if (( fork_exit != 0 )); then
  find "$test_dir/fork-results" -type f \
    \( -name stderr.log -o -name stdout.log -o -name container.log \
       -o -name files.tsv -o -name time.txt -o -name output_status \) \
    -print -exec sed -n '1,160p' {} \;
  exit "$fork_exit"
fi
fork_summary="$(find "$test_dir/fork-results" -name summary.tsv -type f -print -quit)"
grep -q $'^Fork\tPASS\t' "$fork_summary"

set +e
"$project_dir/qualify-archive.sh" \
  --skip-build \
  --executable archive9 \
  --output data9 \
  --entry Bad \
  --expected-size "$fixture_size" \
  --time-limit-seconds 30 \
  --memory-limit-bytes 134217728 \
  --disk-limit-bytes 104857600 \
  --disk-poll-seconds 1 \
  --results "$test_dir/bad-results" \
  "$test_dir/Entries" "$test_dir/enwik9"
bad_exit=$?
set -e

(( bad_exit != 0 ))
bad_summary="$(find "$test_dir/bad-results" -name summary.tsv -type f -print -quit)"
grep -q $'^Bad\tFAIL_MISMATCH\t' "$bad_summary"

set +e
"$project_dir/qualify-archive.sh" \
  --skip-build \
  --executable archive9 \
  --output data9 \
  --entry Nested \
  --expected-size "$fixture_size" \
  --time-limit-seconds 30 \
  --memory-limit-bytes 134217728 \
  --disk-limit-bytes 104857600 \
  --disk-poll-seconds 1 \
  --results "$test_dir/nested-results" \
  "$test_dir/Entries" "$test_dir/enwik9"
nested_exit=$?
set -e
(( nested_exit != 0 ))
nested_summary="$(find "$test_dir/nested-results" -name summary.tsv -type f -print -quit)"
grep -q $'^Nested\tFAIL_EXECUTION\t' "$nested_summary"
nested_stderr="$(find "$test_dir/nested-results" -name stderr.log -type f -print -quit)"
grep -q 'rejected an undeclared additional executable invocation' "$nested_stderr"

set +e
"$project_dir/qualify-archive.sh" \
  --skip-build \
  --runtime-exec-policy process-tree \
  --executable archive9 \
  --output data9 \
  --entry ProcessTree \
  --expected-size "$fixture_size" \
  --time-limit-seconds 30 \
  --memory-limit-bytes 134217728 \
  --disk-limit-bytes 104857600 \
  --disk-poll-seconds 1 \
  --results "$test_dir/process-tree-results" \
  "$test_dir/Entries" "$test_dir/enwik9"
process_tree_exit=$?
set -e
if (( process_tree_exit != 0 )); then
  find "$test_dir/process-tree-results" -type f \
    \( -name stderr.log -o -name execution-events.tsv \
       -o -name time.txt -o -name runtime_exec_policy \) \
    -print -exec sed -n '1,160p' {} \;
  exit "$process_tree_exit"
fi
process_tree_summary="$(find "$test_dir/process-tree-results" \
  -name summary.tsv -type f -print -quit)"
grep -q $'^ProcessTree\tPASS\t' "$process_tree_summary"
process_tree_events="$(find "$test_dir/process-tree-results" \
  -name execution-events.tsv -type f -print -quit)"
grep -q $'\texec-permitted\t.*\t./archive9$' "$process_tree_events"
process_tree_policy="$(find "$test_dir/process-tree-results" \
  -name runtime_exec_policy -type f -print -quit)"
grep -qx process-tree "$process_tree_policy"
process_tree_inputs="$(find "$test_dir/process-tree-results" \
  -name phase-inputs.tsv -type f -print -quit)"
grep -q $'^executable\tarchive9\t[0-9][0-9]*\t[0-9a-f]\{64\}$' \
  "$process_tree_inputs"
grep -q $'^arguments\tdeclared.arguments\t0\t[0-9a-f]\{64\}$' \
  "$process_tree_inputs"
process_tree_peak="$(find "$test_dir/process-tree-results" \
  -name process_tree_peak_rss_bytes -type f -print -quit)"
grep -Eq '^[1-9][0-9]*$' "$process_tree_peak"

set +e
"$project_dir/qualify-archive.sh" \
  --skip-build \
  --executable archive9 \
  --output data9 \
  --entry Memory \
  --expected-size "$fixture_size" \
  --time-limit-seconds 30 \
  --memory-limit-bytes 8388608 \
  --disk-limit-bytes 104857600 \
  --disk-poll-seconds 1 \
  --results "$test_dir/memory-results" \
  "$test_dir/Entries" "$test_dir/enwik9"
memory_exit=$?
set -e

(( memory_exit != 0 ))
memory_summary="$(find "$test_dir/memory-results" -name summary.tsv -type f -print -quit)"
grep -q $'^Memory\tFAIL_MEMORY\t' "$memory_summary"
memory_peak="$(find "$test_dir/memory-results" -name peak_rss_bytes -type f -print -quit)"
(( $(<"$memory_peak") > 8388608 ))

set +e
"$project_dir/qualify-archive.sh" \
  --skip-build \
  --executable archive9 \
  --output data9 \
  --entry AggregateMemory \
  --expected-size "$fixture_size" \
  --time-limit-seconds 30 \
  --memory-limit-bytes 10485760 \
  --disk-limit-bytes 104857600 \
  --disk-poll-seconds 1 \
  --results "$test_dir/aggregate-memory-results" \
  "$test_dir/Entries" "$test_dir/enwik9"
aggregate_memory_exit=$?
set -e
(( aggregate_memory_exit != 0 ))
aggregate_memory_summary="$(find "$test_dir/aggregate-memory-results" \
  -name summary.tsv -type f -print -quit)"
grep -q $'^AggregateMemory\tFAIL_MEMORY\t' "$aggregate_memory_summary"
aggregate_memory_peak="$(find "$test_dir/aggregate-memory-results" \
  -name process_tree_peak_rss_bytes -type f -print -quit)"
(( $(<"$aggregate_memory_peak") > 10485760 ))
aggregate_memory_flag="$(find "$test_dir/aggregate-memory-results" \
  -name process_tree_memory_exceeded -type f -print -quit)"
grep -qx yes "$aggregate_memory_flag"

set +e
timeout --signal=TERM --kill-after=5 30 \
  "$project_dir/qualify-archive.sh" \
  --skip-build \
  --executable archive9 \
  --output data9 \
  --entry CpuLimit \
  --expected-size "$fixture_size" \
  --time-limit-seconds 1 \
  --memory-limit-bytes 134217728 \
  --disk-limit-bytes 104857600 \
  --disk-poll-seconds 1 \
  --results "$test_dir/slow-results" \
  "$test_dir/Entries" "$test_dir/enwik9"
slow_exit=$?
set -e

(( slow_exit != 0 ))
slow_summary="$(find "$test_dir/slow-results" -name summary.tsv -type f -print -quit)"
grep -q $'^CpuLimit\tFAIL_TIME\t' "$slow_summary"
slow_time_flag="$(find "$test_dir/slow-results" \
  -name time_limit_exceeded -type f -print -quit)"
slow_exit_code="$(find "$test_dir/slow-results" \
  -name executable_exit_code -type f -print -quit)"
slow_output_status="$(find "$test_dir/slow-results" \
  -name output_status -type f -print -quit)"
slow_container_log="$(find "$test_dir/slow-results" \
  -name container.log -type f -print -quit)"
grep -qx yes "$slow_time_flag"
grep -qx 0 "$slow_exit_code"
grep -qx found "$slow_output_status"
grep -q 'FAIL_TIME: archive9 exceeded its 1-second allowance and remains running' \
  "$slow_container_log"

echo "archive qualification integration tests passed"
