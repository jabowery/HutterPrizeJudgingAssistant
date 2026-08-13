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
  "$test_dir/Entries/Memory" \
  "$test_dir/Entries/Slow" \
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

cat > "$test_dir/Entries/Slow/archive9" <<'EOF'
#!/bin/sh
while :; do
  :
done
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

chmod 0555 \
  "$test_dir/Entries/Good/archive9" \
  "$test_dir/Entries/Fork/archive9" \
  "$test_dir/Entries/Bad/archive9" \
  "$test_dir/Entries/Nested/archive9" \
  "$test_dir/Entries/Memory/archive9" \
  "$test_dir/Entries/Slow/archive9"
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
  --executable archive9 \
  --output data9 \
  --entry Memory \
  --expected-size "$fixture_size" \
  --time-limit-seconds 30 \
  --memory-limit-bytes 8388608 \
  --cgroup-headroom-bytes 134217728 \
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
  --entry Slow \
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
grep -q $'^Slow\tFAIL_TIME\t' "$slow_summary"

echo "archive qualification integration tests passed"
