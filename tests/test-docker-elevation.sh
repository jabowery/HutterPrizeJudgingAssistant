#!/usr/bin/env bash
set -Eeuo pipefail

readonly project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly test_dir="$(mktemp -d)"
trap 'rm -rf -- "$test_dir"' EXIT

mkdir -p "$test_dir/bin" "$test_dir/entry"
printf 'tiny reference\n' > "$test_dir/enwik9"
printf '#!/bin/sh\nexit 0\n' > "$test_dir/entry/archive9"
chmod 0555 "$test_dir/entry/archive9"

cat > "$test_dir/bin/docker" <<'EOF'
#!/bin/sh
echo 'permission denied while trying to connect to the docker API at unix:///var/run/docker.sock' >&2
exit 1
EOF
cat > "$test_dir/bin/sudo" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "${FAKE_SUDO_LOG:?}"
exit 73
EOF
chmod 0555 "$test_dir/bin/docker" "$test_dir/bin/sudo"

set +e
FAKE_SUDO_LOG="$test_dir/benchmark-sudo.log" \
  PATH="$test_dir/bin:$PATH" \
  "$project_dir/benchmark.sh" \
    --skip-build --results "$test_dir/benchmark-results" \
    > "$test_dir/benchmark.stdout" 2> "$test_dir/benchmark.stderr"
benchmark_exit=$?

FAKE_SUDO_LOG="$test_dir/qualify-sudo.log" \
  PATH="$test_dir/bin:$PATH" \
  "$project_dir/qualify-archive.sh" \
    --executable archive9 \
    --output data9 \
    --expected-size "$(stat --format='%s' "$test_dir/enwik9")" \
    --results "$test_dir/qualify-results" \
    "$test_dir/entry" "$test_dir/enwik9" \
    > "$test_dir/qualify.stdout" 2> "$test_dir/qualify.stderr"
qualify_exit=$?

FAKE_SUDO_LOG="$test_dir/judging-sudo.log" \
  PATH="$test_dir/bin:$PATH" \
  "$project_dir/judging_assistance.sh" \
    --cold-cache \
    --expected-size "$(stat --format='%s' "$test_dir/enwik9")" \
    --work-root "$test_dir/judging-work" \
    --results "$test_dir/judging-results" \
    "$test_dir/entry" "$test_dir/enwik9" \
    > "$test_dir/judging.stdout" 2> "$test_dir/judging.stderr"
judging_exit=$?
set -e

if (( EUID == 0 )); then
  (( benchmark_exit == 2 ))
  (( qualify_exit == 2 ))
  (( judging_exit == 2 ))
  grep -q 'root cannot access the Docker daemon' "$test_dir/benchmark.stderr"
  grep -q 'root cannot access the Docker daemon' "$test_dir/qualify.stderr"
  grep -q 'root cannot access the Docker daemon' "$test_dir/judging.stderr"
  [[ ! -e "$test_dir/benchmark-sudo.log" ]]
  [[ ! -e "$test_dir/qualify-sudo.log" ]]
  [[ ! -e "$test_dir/judging-sudo.log" ]]
else
  (( benchmark_exit == 73 ))
  (( qualify_exit == 73 ))
  (( judging_exit == 73 ))
  grep -q 'Docker daemon access requires elevation; invoking sudo' \
    "$test_dir/benchmark.stderr"
  grep -q 'Docker daemon access requires elevation; invoking sudo' \
    "$test_dir/qualify.stderr"
  grep -q 'Docker daemon access requires elevation; invoking sudo' \
    "$test_dir/judging.stderr"

  mapfile -t benchmark_sudo < "$test_dir/benchmark-sudo.log"
  [[ "${benchmark_sudo[0]}" == -- ]]
  [[ "${benchmark_sudo[1]}" == "$project_dir/benchmark.sh" ]]
  [[ "${benchmark_sudo[2]}" == --skip-build ]]
  [[ "${benchmark_sudo[3]}" == --results ]]
  [[ "${benchmark_sudo[4]}" == "$test_dir/benchmark-results" ]]

  mapfile -t qualify_sudo < "$test_dir/qualify-sudo.log"
  [[ "${qualify_sudo[0]}" == -- ]]
  [[ "${qualify_sudo[1]}" == "$project_dir/qualify-archive.sh" ]]
  [[ "${qualify_sudo[2]}" == --executable ]]
  [[ "${qualify_sudo[3]}" == archive9 ]]

  mapfile -t judging_sudo < "$test_dir/judging-sudo.log"
  [[ "${judging_sudo[0]}" == -- ]]
  [[ "${judging_sudo[1]}" == "$project_dir/judging_assistance.sh" ]]
  [[ "${judging_sudo[2]}" == --cold-cache ]]
fi

[[ ! -e "$test_dir/benchmark-results" ]]
[[ ! -e "$test_dir/qualify-results" ]]
[[ ! -e "$test_dir/judging-results" ]]
[[ ! -e "$test_dir/judging-work" ]]

chmod u+w "$test_dir/bin/docker"
cat > "$test_dir/bin/docker" <<'EOF'
#!/bin/sh
case "$1" in
  info)
    printf '%s\n' '27.0.0'
    ;;
  build)
    ;;
  image)
    if [ "$2" = inspect ]; then
      case " $* " in
        *org.hutterprize.qualification-os-image*)
          printf '%s\n' 'ubuntu:22.04@sha256:58b87898e82351c6cf9cf5b9f3c20257bb9e2dcf33af051e12ce532d7f94e3fe'
          ;;
        *org.hutterprize.qualification-os*)
          printf '%s\n' 'ubuntu-22.04'
          ;;
        *)
          printf '%s\n' 'sha256:automatic-calibration-test'
          ;;
      esac
    else
      exit 92
    fi
    ;;
  version)
    printf '%s\n' '27.0.0'
    ;;
  run)
    case " $* " in
      *'/opt/geekbench/Geekbench-5.5.1-Linux/geekbench5 --cpu'*)
        printf '%s\n' 'Single-Core Score 2000'
        ;;
      *)
        exit 91
        ;;
    esac
    ;;
  *)
    exit 93
    ;;
esac
EOF
chmod 0555 "$test_dir/bin/docker"
mkdir -p "$test_dir/automatic-work"

set +e
PATH="$test_dir/bin:$PATH" \
  "$project_dir/qualify-archive.sh" \
    --executable archive9 \
    --output data9 \
    --expected-size "$(stat --format='%s' "$test_dir/enwik9")" \
    --disk-limit-bytes 1 \
    --work-root "$test_dir/automatic-work" \
    --results "$test_dir/automatic-results" \
    "$test_dir/entry" "$test_dir/enwik9" \
    > "$test_dir/automatic.stdout" 2> "$test_dir/automatic.stderr"
automatic_exit=$?
set -e

(( automatic_exit == 91 ))
grep -q 'Running automatic Geekbench 5 calibration' \
  "$test_dir/automatic.stderr"
automatic_preflight="$(find "$test_dir/automatic-results" \
  -type f -name preflight.env -print -quit)"
[[ -n "$automatic_preflight" ]]
grep -qx 'geekbench5_score=2000' "$automatic_preflight"
grep -qx 'geekbench5_score_source=automatic_container_calibration' \
  "$automatic_preflight"
grep -qx 'time_limit_seconds=126000' "$automatic_preflight"
automatic_calibration="$(find "$test_dir/automatic-results" \
  -type f -name calibration.env -print -quit)"
[[ -n "$automatic_calibration" ]]
grep -qx 'geekbench_single_core_score=2000' "$automatic_calibration"

echo "standalone Docker elevation and automatic calibration tests passed"
