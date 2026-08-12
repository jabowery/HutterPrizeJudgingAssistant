#!/usr/bin/env bash
set -Eeuo pipefail

readonly script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/lib/entry-env.sh"
image=hutter-prize-judge:local
entry_dir=""
compressor_path=""
reference_path="$script_dir/enwik9"
output_path=""
results_path="$script_dir/Results"
work_root=""
geekbench_score=""
time_limit_seconds=""
memory_limit_bytes=10737418240
cgroup_memory_headroom_bytes=1073741824
disk_limit_bytes=100000000000
disk_poll_seconds=10
cpu_limit=1
expected_size=1000000000
active_container=""
active_work_dir=""

usage() {
  cat <<'EOF'
Usage: ./compress-entry.sh [OPTIONS] ENTRY_DIR COMPRESSOR ENWIK9

Run the rebuilt COMPRESSOR offline and unprivileged under its entrant-declared
basename, with the literal argument vector and artifact aliases declared by
ENTRY_DIR/entry.env. No contestant launcher or judge compatibility alias is
used.

Options:
  --output FILE              Copy the generated declared ARCHIVE to FILE
  --results DIR              Evidence directory (default: ./Results)
  --work-root DIR            Required large temporary filesystem
  --geekbench-score N        Geekbench 5 single-core score T
  --time-limit-seconds N     Override the 70000/T-hour limit
  --memory-limit-bytes N     Formal peak-RSS limit (default: 10737418240)
  --cgroup-headroom-bytes N  Supervisor/cache allowance (default: 1073741824)
  --disk-limit-bytes N       Default: 100000000000
  --disk-poll-seconds N      Default: 10
  --cpus N                   Default: 1
  --expected-size N          Expected input bytes (default: 1000000000)
  --image NAME               Default: hutter-prize-judge:local
EOF
}

die() { echo "error: $*" >&2; exit 2; }
read_report() {
  if [[ -r "$1" ]]; then
    tr -d '\r\n' < "$1"
  fi
}
cleanup() {
  [[ -z "$active_container" ]] || docker rm --force "$active_container" >/dev/null 2>&1 || true
  if [[ -n "$active_work_dir" && -d "$active_work_dir" ]]; then
    docker run --rm --network none \
      --mount "type=bind,source=$active_work_dir,target=/work" \
      "$image" /usr/local/bin/clean-work >/dev/null 2>&1 || true
    rmdir -- "$active_work_dir" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

declare -a positional=()
while (( $# > 0 )); do
  case "$1" in
    --output) (( $# >= 2 )) || die "$1 requires a value"; output_path="$2"; shift 2 ;;
    --results) (( $# >= 2 )) || die "$1 requires a value"; results_path="$2"; shift 2 ;;
    --work-root) (( $# >= 2 )) || die "$1 requires a value"; work_root="$2"; shift 2 ;;
    --geekbench-score) (( $# >= 2 )) || die "$1 requires a value"; geekbench_score="$2"; shift 2 ;;
    --time-limit-seconds) (( $# >= 2 )) || die "$1 requires a value"; time_limit_seconds="$2"; shift 2 ;;
    --memory-limit-bytes) (( $# >= 2 )) || die "$1 requires a value"; memory_limit_bytes="$2"; shift 2 ;;
    --cgroup-headroom-bytes) (( $# >= 2 )) || die "$1 requires a value"; cgroup_memory_headroom_bytes="$2"; shift 2 ;;
    --disk-limit-bytes) (( $# >= 2 )) || die "$1 requires a value"; disk_limit_bytes="$2"; shift 2 ;;
    --disk-poll-seconds) (( $# >= 2 )) || die "$1 requires a value"; disk_poll_seconds="$2"; shift 2 ;;
    --cpus) (( $# >= 2 )) || die "$1 requires a value"; cpu_limit="$2"; shift 2 ;;
    --expected-size) (( $# >= 2 )) || die "$1 requires a value"; expected_size="$2"; shift 2 ;;
    --image) (( $# >= 2 )) || die "$1 requires a value"; image="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) positional+=("$1"); shift ;;
  esac
done
(( ${#positional[@]} == 3 )) || die "ENTRY_DIR, COMPRESSOR, and ENWIK9 are required"
entry_dir="${positional[0]}"
compressor_path="${positional[1]}"
reference_path="${positional[2]}"

for numeric_name in memory_limit_bytes cgroup_memory_headroom_bytes disk_limit_bytes disk_poll_seconds expected_size; do
  value="${!numeric_name}"
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || die "$numeric_name must be a positive integer"
done
readonly cgroup_memory_ceiling_bytes="$((memory_limit_bytes + cgroup_memory_headroom_bytes))"
(( cgroup_memory_ceiling_bytes > memory_limit_bytes )) \
  || die "invalid cgroup memory ceiling"
[[ "$cpu_limit" =~ ^[0-9]+([.][0-9]+)?$ ]] \
  && awk -v n="$cpu_limit" 'BEGIN { exit !(n > 0) }' \
  || die "cpus must be positive"
if [[ -n "$time_limit_seconds" ]]; then
  [[ "$time_limit_seconds" =~ ^[1-9][0-9]*$ ]] || die "invalid time limit"
else
  [[ "$geekbench_score" =~ ^[1-9][0-9]*$ ]] \
    || die "--geekbench-score is required unless time is overridden"
  time_limit_seconds="$(awk -v score="$geekbench_score" \
    'BEGIN { print int((70000 * 3600) / score) }')"
fi

[[ -d "$entry_dir" && ! -L "$entry_dir" ]] || die "invalid entry directory: $entry_dir"
hp_manifest_load "$entry_dir/entry.env" || exit 2
hp_manifest_require_linux || exit 2
hp_arguments_validate "$entry_dir/$HP_COMPRESSOR_ARGUMENTS" \
  COMPRESSOR_ARGUMENTS || exit 2
[[ -f "$compressor_path" && ! -L "$compressor_path" ]] || die "invalid compressor"
[[ -f "$reference_path" && ! -L "$reference_path" ]] || die "invalid enwik9"
[[ -n "$work_root" ]] || die "--work-root is required for compression temporary data"
[[ -d "$work_root" && ! -L "$work_root" && -w "$work_root" ]] \
  || die "invalid or unwritable work root: $work_root"
entry_dir="$(realpath -- "$entry_dir")"
compressor_path="$(realpath -- "$compressor_path")"
reference_path="$(realpath -- "$reference_path")"
work_root="$(realpath -- "$work_root")"
[[ "$(stat --format='%s' "$reference_path")" == "$expected_size" ]] \
  || die "enwik9 must be exactly $expected_size bytes"
available_bytes="$(df --block-size=1 --output=avail "$work_root" | awk 'NR == 2 { print $1 }')"
(( available_bytes >= disk_limit_bytes )) \
  || die "work filesystem has $available_bytes free bytes; $disk_limit_bytes required"
docker image inspect "$image" >/dev/null || die "missing image: $image"

mkdir -p -- "$results_path"
results_path="$(realpath -- "$results_path")"
readonly stamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
readonly entry_name="$(basename -- "$entry_dir")"
readonly result_dir="$results_path/$stamp/compression-$entry_name"
mkdir -p -- "$result_dir"
active_work_dir="$(mktemp -d -- "$work_root/hutter-compress-$stamp.XXXXXX")"
chmod 0755 "$active_work_dir"

docker run --rm \
  --network none --read-only \
  --cap-drop ALL --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER \
  --security-opt no-new-privileges=true \
  --mount "type=bind,source=$compressor_path,target=/submission/executable,readonly" \
  --mount "type=bind,source=$entry_dir/$HP_COMPRESSOR_ARGUMENTS,target=/submission/arguments,readonly" \
  --mount "type=bind,source=$active_work_dir,target=/work" \
  --env "EXECUTABLE_NAME=$HP_COMPRESSOR" \
  --env "ARGUMENTS_NAME=$HP_COMPRESSOR_ARGUMENTS" \
  --env "INPUT_NAME=enwik9" \
  --env "OUTPUT_NAME=$HP_ARCHIVE" \
  "$image" /usr/local/bin/init-compression

active_container="$(docker create \
  --network none --read-only \
  --cpus "$cpu_limit" \
  --memory "$cgroup_memory_ceiling_bytes" --memory-swap "$cgroup_memory_ceiling_bytes" \
  --pids-limit 4096 --ulimit nofile=65536:65536 \
  --cap-drop ALL \
  --cap-add SETUID --cap-add SETGID --cap-add KILL \
  --cap-add DAC_READ_SEARCH --cap-add SETPCAP --cap-add SYS_CHROOT \
  --cap-add SYS_PTRACE \
  --security-opt no-new-privileges=true \
  --tmpfs /run:rw,nosuid,nodev,noexec,size=16777216 \
  --tmpfs /opt/contestant-root/proc/self:rw,nosuid,nodev,noexec,mode=0755,size=4096 \
  --mount type=bind,source=/dev/null,target=/opt/contestant-root/dev/null \
  --mount "type=bind,source=$active_work_dir,target=/work" \
  --mount "type=bind,source=$active_work_dir,target=/opt/contestant-root/work" \
  --mount "type=bind,source=$reference_path,target=/work/run/enwik9,readonly" \
  --mount "type=bind,source=$reference_path,target=/opt/contestant-root/work/run/enwik9,readonly" \
  --env "EXECUTABLE_NAME=$HP_COMPRESSOR" \
  --env "ARGUMENTS_NAME=$HP_COMPRESSOR_ARGUMENTS" \
  --env "INPUT_NAME=enwik9" \
  --env "OUTPUT_NAME=$HP_ARCHIVE" \
  --env "TIME_LIMIT_SECONDS=$time_limit_seconds" \
  --env "MEMORY_LIMIT_BYTES=$memory_limit_bytes" \
  --env "DISK_LIMIT_BYTES=$disk_limit_bytes" \
  --env "DISK_POLL_SECONDS=$disk_poll_seconds" \
  "$image" /usr/local/bin/run-compressor)"

echo "[$entry_name] compressing offline as UID 65532 (limit: ${time_limit_seconds}s)" >&2
docker start "$active_container" >/dev/null
docker wait "$active_container" > "$result_dir/container-exit-code"
docker inspect "$active_container" > "$result_dir/container-inspect.json"
docker logs "$active_container" > "$result_dir/container.log" 2>&1 || true
docker cp "$active_container:/work/report/." "$result_dir" >/dev/null 2>&1 || true

container_exit="$(read_report "$result_dir/container-exit-code")"
oom_killed="$(docker inspect "$active_container" --format '{{.State.OOMKilled}}')"
resource_violation="$(read_report "$result_dir/resource_violation")"
archive_status="$(read_report "$result_dir/output_status")"
if [[ "$oom_killed" == true ]]; then
  status=FAIL_MEMORY
elif [[ "$resource_violation" == disk ]]; then
  status=FAIL_DISK
elif [[ "$resource_violation" == time ]]; then
  status=FAIL_TIME
elif [[ "$resource_violation" == memory ]]; then
  status=FAIL_MEMORY
elif [[ "$container_exit" != 0 ]]; then
  status=FAIL_EXECUTION
elif [[ "$archive_status" != found ]]; then
  status=FAIL_OUTPUT
else
  status=PASS
fi

if [[ "$status" == PASS ]]; then
  if [[ -z "$output_path" ]]; then
    output_path="$result_dir/$HP_ARCHIVE"
  fi
  mkdir -p -- "$(dirname -- "$output_path")"
  docker cp "$active_container:/work/run/$HP_ARCHIVE" "$output_path"
  chmod 0555 "$output_path"
  output_path="$(realpath -- "$output_path")"
fi

{
  echo "entry=$entry_name"
  echo "status=$status"
  echo "geekbench5_score=${geekbench_score:-not_used_time_override}"
  echo "time_limit_seconds=$time_limit_seconds"
  echo "cpu_limit=$cpu_limit"
  echo "memory_limit_bytes=$memory_limit_bytes"
  echo "cgroup_memory_headroom_bytes=$cgroup_memory_headroom_bytes"
  echo "cgroup_memory_ceiling_bytes=$cgroup_memory_ceiling_bytes"
  echo "peak_rss_kib=$(read_report "$result_dir/peak_rss_kib")"
  echo "peak_rss_bytes=$(read_report "$result_dir/peak_rss_bytes")"
  echo "disk_limit_bytes=$disk_limit_bytes"
  echo "network=none"
  echo "compressor_name=$HP_COMPRESSOR"
  echo "compressor_bytes=$(stat --format='%s' "$compressor_path")"
  echo "compressor_sha256=$(sha256sum "$compressor_path" | awk '{print $1}')"
  echo "command_line_file=$HP_COMPRESSOR_ARGUMENTS"
  echo "command_line_bytes=$(stat --format='%s' "$entry_dir/$HP_COMPRESSOR_ARGUMENTS")"
  echo "command_line_sha256=$(sha256sum "$entry_dir/$HP_COMPRESSOR_ARGUMENTS" | awk '{print $1}')"
  echo "archive_path=$output_path"
  [[ "$status" != PASS ]] || echo "archive_bytes=$(stat --format='%s' "$output_path")"
  [[ "$status" != PASS ]] || echo "archive_sha256=$(sha256sum "$output_path" | awk '{print $1}')"
} > "$result_dir/compression.env"

echo "[$entry_name] compression $status" >&2
[[ "$status" == PASS ]] || exit 1
printf '%s\n' "$output_path"
