#!/usr/bin/env bash
set -Eeuo pipefail

readonly script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

image="hutter-prize-judging:local"
entries_path=""
reference_path=""
results_path="$script_dir/Results"
work_root=""
expected_size=1000000000
expected_output=""
archive_name=""
arguments_file=""
payload_file=""
payload_name=""
geekbench_score=""
time_limit_seconds=""
memory_limit_bytes=10737418240
cgroup_memory_headroom_bytes=1073741824
disk_limit_bytes=100000000000
disk_poll_seconds=10
cpu_limit=1
record_size=110793128
preflight_only=false
skip_build=false
keep_work=false
container_id_file=""
declare -a selected_entries=()

active_container=""
active_volume=""
active_work_dir=""

usage() {
  cat <<'EOF'
Usage:
  ./qualify-archive.sh [OPTIONS] [ENTRIES_DIR [ENWIK9]]

Run one explicitly named contestant executable from every immediate
subdirectory of ENTRIES_DIR, or from ENTRIES_DIR itself when it contains that
executable. Artifact names are never inferred.

Options:
  --enwik9 FILE              Reference enwik9 (default: ./enwik9)
  --entry NAME               Process only NAME; may be repeated
  --results DIR              Result directory (default: ./Results)
  --work-root DIR            Put isolated work directories on this filesystem
  --executable NAME          Required entrant-declared executable basename
  --arguments-file FILE      Literal argument vector, one argument per line
  --payload-file FILE        Optional read-only input payload
  --payload-name NAME        Entrant-declared basename for that payload
  --output NAME              Required entrant-declared output basename
  --geekbench-score N        Geekbench 5 score T (required unless time overridden)
  --time-limit-seconds N     Override the official 70000/T-hour limit
  --memory-limit-bytes N     Formal peak-RSS limit (default: 10737418240 = 10 GiB)
  --cgroup-headroom-bytes N  Supervisor/cache allowance (default: 1073741824)
  --disk-limit-bytes N       Sampled allocated-disk limit (default: 100000000000)
  --disk-poll-seconds N      Disk sampling interval (default: 10)
  --cpus N                   CPU capacity (default: 1)
  --record-size N            Previous record L (default: 110793128)
  --expected-size N          Reference/output size (default: 1000000000)
  --image NAME               Docker image tag
  --skip-build               Use an existing image
  --preflight-only           Inventory and score without executing submissions
  --keep-work                Keep per-entry Docker volumes for inspection
  --container-id-file FILE   Internal active-container handoff for parent cleanup
  -h, --help                 Show this help

The second positional argument is equivalent to --enwik9. The reference is
never mounted in the container that executes the submitted program.
EOF
}

die() {
  echo "error: $*" >&2
  exit 2
}

cleanup_active() {
  if [[ -n "$active_container" ]]; then
    docker rm --force "$active_container" >/dev/null 2>&1 || true
    active_container=""
  fi
  if [[ -n "$active_volume" && "$keep_work" != true ]]; then
    docker volume rm --force "$active_volume" >/dev/null 2>&1 || true
    active_volume=""
  fi
  if [[ -n "$active_work_dir" && "$keep_work" != true ]]; then
    docker run --rm \
      --network none \
      --mount "type=bind,source=$active_work_dir,target=/work" \
      "$image" /usr/local/bin/clean-work >/dev/null 2>&1 || true
    rmdir -- "$active_work_dir" >/dev/null 2>&1 || true
    active_work_dir=""
  fi
  if [[ -n "$container_id_file" ]]; then
    rm -f -- "$container_id_file"
  fi
}

trap cleanup_active EXIT
trap 'exit 130' INT TERM

require_value() {
  (( $# >= 2 )) || die "$1 requires a value"
}

while (( $# > 0 )); do
  case "$1" in
    --enwik9)
      require_value "$@"
      reference_path="$2"
      shift 2
      ;;
    --entry)
      require_value "$@"
      selected_entries+=("$2")
      shift 2
      ;;
    --results)
      require_value "$@"
      results_path="$2"
      shift 2
      ;;
    --work-root)
      require_value "$@"
      work_root="$2"
      shift 2
      ;;
    --executable)
      require_value "$@"
      archive_name="$2"
      shift 2
      ;;
    --arguments-file)
      require_value "$@"
      arguments_file="$2"
      shift 2
      ;;
    --payload-file)
      require_value "$@"
      payload_file="$2"
      shift 2
      ;;
    --payload-name)
      require_value "$@"
      payload_name="$2"
      shift 2
      ;;
    --output)
      require_value "$@"
      expected_output="$2"
      shift 2
      ;;
    --geekbench-score)
      require_value "$@"
      geekbench_score="$2"
      shift 2
      ;;
    --time-limit-seconds)
      require_value "$@"
      time_limit_seconds="$2"
      shift 2
      ;;
    --memory-limit-bytes)
      require_value "$@"
      memory_limit_bytes="$2"
      shift 2
      ;;
    --cgroup-headroom-bytes)
      require_value "$@"
      cgroup_memory_headroom_bytes="$2"
      shift 2
      ;;
    --disk-limit-bytes)
      require_value "$@"
      disk_limit_bytes="$2"
      shift 2
      ;;
    --disk-poll-seconds)
      require_value "$@"
      disk_poll_seconds="$2"
      shift 2
      ;;
    --cpus)
      require_value "$@"
      cpu_limit="$2"
      shift 2
      ;;
    --record-size)
      require_value "$@"
      record_size="$2"
      shift 2
      ;;
    --expected-size)
      require_value "$@"
      expected_size="$2"
      shift 2
      ;;
    --image)
      require_value "$@"
      image="$2"
      shift 2
      ;;
    --skip-build)
      skip_build=true
      shift
      ;;
    --preflight-only)
      preflight_only=true
      shift
      ;;
    --keep-work)
      keep_work=true
      shift
      ;;
    --container-id-file)
      require_value "$@"
      container_id_file="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      if [[ -z "$entries_path" ]]; then
        entries_path="$1"
      elif [[ -z "$reference_path" ]]; then
        reference_path="$1"
      else
        die "unexpected positional argument: $1"
      fi
      shift
      ;;
  esac
done

(( $# == 0 )) || die "unexpected positional arguments"

entries_path="${entries_path:-$script_dir/Entries}"
reference_path="${reference_path:-$script_dir/enwik9}"

for numeric_value in \
  expected_size memory_limit_bytes cgroup_memory_headroom_bytes disk_limit_bytes \
  disk_poll_seconds record_size; do
  value="${!numeric_value}"
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || die "$numeric_value must be a positive integer"
done
readonly cgroup_memory_ceiling_bytes="$((memory_limit_bytes + cgroup_memory_headroom_bytes))"
(( cgroup_memory_ceiling_bytes > memory_limit_bytes )) \
  || die "invalid cgroup memory ceiling"

if [[ -n "$container_id_file" ]]; then
  [[ ! -e "$container_id_file" && ! -L "$container_id_file" ]] \
    || die "container ID file already exists: $container_id_file"
  container_id_parent="$(dirname -- "$container_id_file")"
  [[ -d "$container_id_parent" && ! -L "$container_id_parent" \
      && -w "$container_id_parent" ]] \
    || die "invalid container ID file directory: $container_id_parent"
  container_id_file="$(realpath --canonicalize-missing -- "$container_id_file")"
fi
[[ "$cpu_limit" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "cpus must be a positive number"
awk -v cpus="$cpu_limit" 'BEGIN { exit !(cpus > 0) }' \
  || die "cpus must be greater than zero"

if [[ -n "$geekbench_score" ]]; then
  [[ "$geekbench_score" =~ ^[1-9][0-9]*$ ]] \
    || die "geekbench_score must be a positive integer"
fi

if [[ -n "$time_limit_seconds" ]]; then
  [[ "$time_limit_seconds" =~ ^[1-9][0-9]*$ ]] \
    || die "time_limit_seconds must be a positive integer"
elif [[ "$preflight_only" == true && -z "$geekbench_score" ]]; then
  time_limit_seconds=not_calibrated
else
  [[ -n "$geekbench_score" ]] \
    || die "--geekbench-score is required unless --time-limit-seconds is supplied (use ./benchmark.sh)"
  time_limit_seconds="$(awk -v score="$geekbench_score" \
    'BEGIN { print int((70000 * 3600) / score) }')"
fi

[[ -n "$archive_name" && "$archive_name" =~ ^[A-Za-z0-9._-]+$ ]] \
  || die "executable must be a plain file name"
[[ -z "$payload_name" || "$payload_name" =~ ^[A-Za-z0-9._-]+$ ]] \
  || die "payload name must be a plain file name"
if [[ -n "$arguments_file" ]]; then
  [[ -f "$arguments_file" && ! -L "$arguments_file" ]] \
    || die "invalid arguments file: $arguments_file"
  arguments_file="$(realpath -- "$arguments_file")"
fi
if [[ -n "$payload_file" ]]; then
  [[ -n "$payload_name" ]] || die "--payload-file requires --payload-name"
  [[ -f "$payload_file" && ! -L "$payload_file" ]] \
    || die "invalid payload file: $payload_file"
  payload_file="$(realpath -- "$payload_file")"
elif [[ -n "$payload_name" ]]; then
  die "--payload-name requires --payload-file"
fi
[[ -n "$expected_output" && "$expected_output" =~ ^[A-Za-z0-9._-]+$ ]] \
  || die "--output is required and must be a plain file name"

[[ -d "$entries_path" ]] || die "entries directory not found: $entries_path"
entries_path="$(realpath -- "$entries_path")"

if [[ "$preflight_only" != true ]]; then
  [[ -f "$reference_path" && ! -L "$reference_path" ]] \
    || die "reference file not found or is a symbolic link: $reference_path"
  reference_path="$(realpath -- "$reference_path")"
  actual_reference_size="$(stat --format='%s' -- "$reference_path")"
  [[ "$actual_reference_size" == "$expected_size" ]] \
    || die "reference is $actual_reference_size bytes; expected $expected_size"
fi

mkdir -p -- "$results_path"
results_path="$(realpath -- "$results_path")"
readonly run_stamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
readonly run_results="$results_path/$run_stamp"
mkdir -p -- "$run_results"

if [[ "$preflight_only" != true ]]; then
  command -v docker >/dev/null || die "docker is not installed"
  timeout 30 docker info >/dev/null \
    || die "Docker daemon is unavailable or did not answer within 30 seconds"
  if [[ "$skip_build" != true ]]; then
    docker build --tag "$image" "$script_dir"
  else
    docker image inspect "$image" >/dev/null \
      || die "Docker image does not exist: $image"
  fi

  if [[ -n "$work_root" ]]; then
    [[ -d "$work_root" && ! -L "$work_root" ]] \
      || die "work root is not a regular directory: $work_root"
    [[ -w "$work_root" ]] || die "work root is not writable: $work_root"
    work_root="$(realpath -- "$work_root")"
    work_filesystem_path="$work_root"
  else
    work_filesystem_path="$(docker info --format '{{.DockerRootDir}}')"
  fi

  work_available_bytes="$(df --block-size=1 --output=avail "$work_filesystem_path" \
    | awk 'NR == 2 { print $1 }')"
  [[ "$work_available_bytes" =~ ^[0-9]+$ ]] \
    || die "could not determine free space for $work_filesystem_path"
  (( work_available_bytes >= disk_limit_bytes )) \
    || die "work filesystem has $work_available_bytes free bytes; disk limit requires $disk_limit_bytes (use --work-root)"
fi

declare -a entry_dirs=()
if (( ${#selected_entries[@]} > 0 )); then
  for selected_entry in "${selected_entries[@]}"; do
    [[ "$selected_entry" != */* && "$selected_entry" != . && "$selected_entry" != .. ]] \
      || die "entry names supplied with --entry may not contain slashes"
    [[ -d "$entries_path/$selected_entry" ]] \
      || die "selected entry not found: $selected_entry"
    entry_dirs+=("$entries_path/$selected_entry")
  done
elif [[ -f "$entries_path/$archive_name" ]]; then
  entry_dirs+=("$entries_path")
else
  while IFS= read -r -d '' entry_dir; do
    entry_dirs+=("$entry_dir")
  done < <(find -P "$entries_path" -mindepth 1 -maxdepth 1 -type d \
             -print0 | sort -z)
fi

(( ${#entry_dirs[@]} > 0 )) || die "no entry directories found in $entries_path"

summary_file="$run_results/summary.tsv"
printf 'entry\tstatus\tarchive_bytes\tcompressor_bytes\ttotal_bytes\timprovement_percent\tresult_dir\n' \
  > "$summary_file"

image_id="not-built"
docker_version="not-run"
if [[ "$preflight_only" != true ]]; then
  image_id="$(docker image inspect "$image" --format '{{.Id}}')"
  docker_version="$(docker version --format '{{.Server.Version}}')"
fi

overall_status=0

read_report() {
  local report_file="$1"
  if [[ -r "$report_file" ]]; then
    tr -d '\r\n' < "$report_file"
  fi
}

for entry_dir in "${entry_dirs[@]}"; do
  entry_name="$(basename -- "$entry_dir")"
  if [[ "$entry_name" == *$'\n'* || "$entry_name" == *$'\t'* ]]; then
    echo "Skipping entry whose name contains a tab or newline: $entry_dir" >&2
    overall_status=1
    continue
  fi

  entry_results="$run_results/$entry_name"
  mkdir -p -- "$entry_results"
  archive_path="$entry_dir/$archive_name"

  if [[ ! -f "$archive_path" || -L "$archive_path" ]]; then
    echo "[$entry_name] FAIL_PREFLIGHT: missing regular $archive_name" >&2
    printf '%s\tFAIL_PREFLIGHT\t\t\t\t\t%s\n' \
      "$entry_name" "$entry_results" >> "$summary_file"
    overall_status=1
    continue
  fi

  archive_path="$(realpath -- "$archive_path")"
  archive_bytes="$(stat --format='%s' -- "$archive_path")"
  archive_sha256="$(sha256sum -- "$archive_path" | awk '{print $1}')"

  selected_compressor=""

  compressor_bytes=""
  total_bytes=""
  improvement_percent=""
  one_percent_eligible=unknown
  score_status=incomplete_missing_compressor
  prize_threshold="$(awk -v record="$record_size" 'BEGIN { print int(record * 0.99) }')"
  compressor_budget="$((prize_threshold - archive_bytes))"
  if [[ -n "$selected_compressor" ]]; then
    compressor_bytes="$(stat --format='%s' -- "$selected_compressor")"
    total_bytes="$((archive_bytes + compressor_bytes))"
    improvement_percent="$(awk -v total="$total_bytes" -v record="$record_size" \
      'BEGIN { printf "%.6f", 100 * (record - total) / record }')"
    score_status=complete
    if (( total_bytes <= prize_threshold )); then
      one_percent_eligible=yes
    else
      one_percent_eligible=no
    fi
  fi

  {
    echo "entry=$entry_name"
    echo "entry_directory=$entry_dir"
    echo "archive_file=$archive_name"
    echo "archive_bytes=$archive_bytes"
    echo "archive_sha256=$archive_sha256"
    echo "compressor_file=${selected_compressor##*/}"
    echo "compressor_bytes=$compressor_bytes"
    echo "formal_total_bytes=$total_bytes"
    echo "previous_record_bytes=$record_size"
    echo "one_percent_threshold_bytes=$prize_threshold"
    echo "compressor_budget_at_one_percent_bytes=$compressor_budget"
    echo "score_status=$score_status"
    echo "one_percent_eligible=$one_percent_eligible"
    echo "improvement_percent=$improvement_percent"
    echo "expected_output=$expected_output"
    echo "expected_output_bytes=$expected_size"
    echo "geekbench5_score=${geekbench_score:-not_used_time_override}"
    echo "time_limit_seconds=$time_limit_seconds"
    echo "cpu_limit=$cpu_limit"
    echo "memory_limit_bytes=$memory_limit_bytes"
    echo "cgroup_memory_headroom_bytes=$cgroup_memory_headroom_bytes"
    echo "cgroup_memory_ceiling_bytes=$cgroup_memory_ceiling_bytes"
    echo "disk_limit_bytes=$disk_limit_bytes"
    echo "work_root=${work_root:-docker-managed-volume}"
    echo "judging_image=$image"
    echo "judging_image_id=$image_id"
    echo "docker_server_version=$docker_version"
  } > "$entry_results/preflight.env"

  find -P "$entry_dir" -mindepth 1 -maxdepth 1 -type f \
    -printf '%f\t%s bytes\n' | sort > "$entry_results/files.tsv"

  if [[ "$preflight_only" == true ]]; then
    status=PREFLIGHT_OK
    echo "[$entry_name] $status: archive is $archive_bytes bytes"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$entry_name" "$status" "$archive_bytes" "$compressor_bytes" \
      "$total_bytes" "$improvement_percent" "$entry_results" >> "$summary_file"
    continue
  fi

  echo "[$entry_name] staging executable $archive_name ($archive_bytes bytes)"
  declare -a work_mount_rw=()
  declare -a work_mount_ro=()
  if [[ -n "$work_root" ]]; then
    active_work_dir="$(mktemp -d -- "$work_root/hutter-prize-$run_stamp.XXXXXX")"
    chmod 0755 "$active_work_dir"
    work_mount_rw=(--mount "type=bind,source=$active_work_dir,target=/work")
    work_mount_ro=(--mount "type=bind,source=$active_work_dir,target=/work,readonly")
    work_mount_sandbox_rw=(
      --mount "type=bind,source=$active_work_dir,target=/opt/contestant-root/work"
    )
  else
    active_volume="$(docker volume create \
      --label hutter-prize-judging=true \
      --label "hutter-prize-run=$run_stamp" \
      --label "hutter-prize-entry=$entry_name")"
    work_mount_rw=(--mount "type=volume,source=$active_volume,target=/work")
    work_mount_ro=(--mount "type=volume,source=$active_volume,target=/work,readonly")
    work_mount_sandbox_rw=(
      --mount "type=volume,source=$active_volume,target=/opt/contestant-root/work"
    )
  fi

  declare -a invocation_mounts=(
    --mount "type=bind,source=$archive_path,target=/submission/executable,readonly"
  )
  arguments_runtime_name=declared.arguments
  if [[ -n "$arguments_file" ]]; then
    arguments_runtime_name="$(basename -- "$arguments_file")"
    invocation_mounts+=(
      --mount "type=bind,source=$arguments_file,target=/submission/arguments,readonly"
    )
  fi
  if [[ -n "$payload_file" ]]; then
    invocation_mounts+=(
      --mount "type=bind,source=$payload_file,target=/submission/payload,readonly"
    )
  fi

  docker run --rm \
    --network none \
    --read-only \
    --cap-drop ALL \
    --cap-add CHOWN \
    --cap-add DAC_OVERRIDE \
    --cap-add FOWNER \
    --security-opt no-new-privileges=true \
    "${invocation_mounts[@]}" \
    "${work_mount_rw[@]}" \
    --env "EXECUTABLE_NAME=$archive_name" \
    --env "ARGUMENTS_NAME=$arguments_runtime_name" \
    --env "PAYLOAD_NAME=$payload_name" \
    "$image" /usr/local/bin/init-work

  active_container="$(docker create \
    --network none \
    --read-only \
    --cpus "$cpu_limit" \
    --memory "$cgroup_memory_ceiling_bytes" \
    --memory-swap "$cgroup_memory_ceiling_bytes" \
    --pids-limit 4096 \
    --ulimit nofile=65536:65536 \
    --cap-drop ALL \
    --cap-add SETUID \
    --cap-add SETGID \
    --cap-add KILL \
    --cap-add DAC_READ_SEARCH \
    --cap-add SETPCAP \
    --cap-add SYS_CHROOT \
    --cap-add SYS_PTRACE \
    --security-opt no-new-privileges=true \
    --tmpfs /run:rw,nosuid,nodev,noexec,size=16777216 \
    --tmpfs /opt/contestant-root/proc/self:rw,nosuid,nodev,noexec,mode=0755,size=4096 \
    --mount type=bind,source=/dev/null,target=/opt/contestant-root/dev/null \
    "${work_mount_rw[@]}" \
    "${work_mount_sandbox_rw[@]}" \
    --env "EXPECTED_SIZE=$expected_size" \
    --env "EXPECTED_OUTPUT=$expected_output" \
    --env "EXECUTABLE_NAME=$archive_name" \
    --env "ARGUMENTS_NAME=$arguments_runtime_name" \
    --env "TIME_LIMIT_SECONDS=$time_limit_seconds" \
    --env "MEMORY_LIMIT_BYTES=$memory_limit_bytes" \
    --env "DISK_LIMIT_BYTES=$disk_limit_bytes" \
    --env "DISK_POLL_SECONDS=$disk_poll_seconds" \
    "$image" /usr/local/bin/run-archive)"

  if [[ -n "$container_id_file" ]]; then
    printf '%s\n' "$active_container" > "$container_id_file"
  fi

  echo "[$entry_name] running without network/reference access (limit: ${time_limit_seconds}s)"
  docker start "$active_container" >/dev/null
  docker wait "$active_container" > "$entry_results/container-exit-code"
  if ! docker inspect "$active_container" \
      > "$entry_results/container-inspect.json" 2>/dev/null; then
    # A full-flow parent may remove this container to cancel parallel work
    # after another required stage fails. EXIT cleanup removes its work area.
    exit 130
  fi
  docker logs "$active_container" > "$entry_results/container.log" 2>&1 || true
  docker cp "$active_container:/work/report/." "$entry_results" >/dev/null 2>&1 || true

  container_exit_code="$(read_report "$entry_results/container-exit-code")"
  oom_killed="$(docker inspect "$active_container" --format '{{.State.OOMKilled}}')"
  resource_violation="$(read_report "$entry_results/resource_violation")"
  output_status="$(read_report "$entry_results/output_status")"

  verification_output=""
  verification_exit=1
  if [[ -r "$entry_results/output_name" ]]; then
    set +e
    verification_output="$(docker run --rm \
      --network none \
      --read-only \
      --cap-drop ALL \
      --cap-add DAC_READ_SEARCH \
      --security-opt no-new-privileges=true \
      "${work_mount_ro[@]}" \
      --mount "type=bind,source=$reference_path,target=/reference/enwik9,readonly" \
      "$image" /usr/local/bin/verify-output 2>&1)"
    verification_exit=$?
    set -e
    printf '%s\n' "$verification_output" > "$entry_results/verification.env"
  fi

  if [[ "$oom_killed" == true ]]; then
    status=FAIL_MEMORY
  elif [[ "$resource_violation" == disk ]]; then
    status=FAIL_DISK
  elif [[ "$resource_violation" == time ]]; then
    status=FAIL_TIME
  elif [[ "$resource_violation" == memory ]]; then
    status=FAIL_MEMORY
  elif [[ "$container_exit_code" != 0 ]]; then
    status=FAIL_EXECUTION
  elif [[ "$output_status" != found ]]; then
    status=FAIL_OUTPUT
  elif (( verification_exit != 0 )); then
    status=FAIL_MISMATCH
  else
    status=PASS
  fi

  echo "[$entry_name] $status"
  if [[ "$status" != PASS ]]; then
    overall_status=1
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$entry_name" "$status" "$archive_bytes" "$compressor_bytes" \
    "$total_bytes" "$improvement_percent" "$entry_results" >> "$summary_file"

  docker rm "$active_container" >/dev/null
  active_container=""
  if [[ -n "$container_id_file" ]]; then
    rm -f -- "$container_id_file"
  fi
  if [[ "$keep_work" == true && -n "$active_volume" ]]; then
    echo "[$entry_name] kept Docker volume: $active_volume"
    echo "$active_volume" > "$entry_results/docker-volume"
    active_volume=""
  elif [[ -n "$active_volume" ]]; then
    docker volume rm "$active_volume" >/dev/null
    active_volume=""
  fi
  if [[ "$keep_work" == true && -n "$active_work_dir" ]]; then
    echo "[$entry_name] kept work directory: $active_work_dir"
    echo "$active_work_dir" > "$entry_results/work-directory"
    active_work_dir=""
  elif [[ -n "$active_work_dir" ]]; then
    docker run --rm \
      --network none \
      --mount "type=bind,source=$active_work_dir,target=/work" \
      "$image" /usr/local/bin/clean-work >/dev/null
    rmdir -- "$active_work_dir"
    active_work_dir=""
  fi
done

{
  echo "Hutter Prize judging run: $run_stamp"
  echo "Results: $run_results"
  echo "Entries: $entries_path"
  echo "Reference: $([[ "$preflight_only" == true ]] && echo not-used || echo "$reference_path")"
  if [[ -n "$geekbench_score" ]]; then
    echo "Rule time formula: 70000/$geekbench_score hours = $time_limit_seconds seconds"
  else
    echo "Time limit: $time_limit_seconds seconds (explicit override; no Geekbench score)"
  fi
  echo "Memory peak-RSS limit: $memory_limit_bytes bytes"
  echo "Cgroup ceiling: $cgroup_memory_ceiling_bytes bytes"
  echo "Disk limit: $disk_limit_bytes allocated bytes (sampled every $disk_poll_seconds seconds)"
  echo "Work storage: ${work_root:-Docker-managed volume}"
  echo
  column -t -s $'\t' "$summary_file" 2>/dev/null || cat "$summary_file"
} | tee "$run_results/report.txt"

exit "$overall_status"
