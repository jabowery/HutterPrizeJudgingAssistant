#!/usr/bin/env bash
set -Eeuo pipefail

readonly project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
mkdir -p "$test_root/bin"

cat > "$test_root/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -eu
case "$1" in
  info)
    printf '%s\n' 27.0.0
    ;;
  image)
    case " $* " in
      *org.hutterprize.qualification-os-image*)
        printf '%s\n' 'ubuntu:22.04@sha256:58b87898e82351c6cf9cf5b9f3c20257bb9e2dcf33af051e12ce532d7f94e3fe'
        ;;
      *org.hutterprize.qualification-os*)
        printf '%s\n' ubuntu-22.04
        ;;
      *)
        printf '%s\n' sha256:benchmark-retrieval-test
        ;;
    esac
    ;;
  run)
    printf '%s\n' 'Upload succeeded. Visit the following link and view your results online:'
    printf '%s\n' 'https://browser.geekbench.com/v5/cpu/24650161'
    ;;
  version)
    printf '%s\n' 27.0.0
    ;;
  *)
    exit 90
    ;;
esac
EOF

cat > "$test_root/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -eu
last="${!#}"
printf '%s\n' "$*" >> "$FAKE_CURL_LOG"
case "$last" in
  https://browser.geekbench.com/*)
    exit 22
    ;;
  https://r.jina.ai/*)
    count=0
    [[ ! -f "$FAKE_CURL_COUNT" ]] || count="$(< "$FAKE_CURL_COUNT")"
    count=$((count + 1))
    printf '%s\n' "$count" > "$FAKE_CURL_COUNT"
    if (( count == 1 )); then
      printf '%s\n' 'Title: Just a moment...' 'Performing security verification'
    else
      printf '%s\n' '1626' 'Single-Core Score' '12076' 'Multi-Core Score'
    fi
    ;;
  *)
    exit 91
    ;;
esac
EOF

cat > "$test_root/bin/sleep" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$FAKE_SLEEP_LOG"
EOF

chmod 0555 "$test_root/bin/docker" "$test_root/bin/curl" "$test_root/bin/sleep"

FAKE_CURL_LOG="$test_root/curl.log" \
FAKE_CURL_COUNT="$test_root/curl.count" \
FAKE_SLEEP_LOG="$test_root/sleep.log" \
PATH="$test_root/bin:$PATH" \
  "$project_dir/benchmark.sh" \
    --skip-build \
    --results "$test_root/results" \
    > "$test_root/stdout.log" \
    2> "$test_root/stderr.log"

grep -qx 1626 "$test_root/stdout.log"
grep -qx 2 "$test_root/curl.count"
grep -q 'X-No-Cache: true' "$test_root/curl.log"
grep -q 'retrying score retrieval (1/6)' "$test_root/stderr.log"
grep -qx 10 "$test_root/sleep.log"

calibration="$(find "$test_root/results" -name calibration.env -type f -print -quit)"
[[ -n "$calibration" ]]
grep -qx 'geekbench_single_core_score=1626' "$calibration"
grep -qx 'geekbench_score_source=jina_reader_of_official_result' "$calibration"

evidence="$(find "$test_root/results" -name result-via-jina.md -type f -print -quit)"
[[ -n "$evidence" ]]
grep -q '^Single-Core Score$' "$evidence"

echo "Geekbench result retrieval tests passed"
