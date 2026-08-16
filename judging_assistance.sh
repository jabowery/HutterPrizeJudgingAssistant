#!/usr/bin/env bash
set -Eeuo pipefail

readonly script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly -a original_argv=("$@")
source "$script_dir/lib/entry-env.sh"
source "$script_dir/lib/resource-units.sh"
image=hutter-prize-judging:local
entry_dir=""
reference_path="$script_dir/enwik9"
results_path="$script_dir/Results"
work_root=""
geekbench_score=""
memory_limit_bytes=10737418240
cgroup_memory_headroom_bytes=1073741824
disk_limit_bytes=100000000000
disk_poll_seconds=10
cpu_limit=1
job_slots=2
record_size=110793128
expected_size=1000000000
active_stage_root=""
qualification_pid=""
qualification_container_file=""
results_path_created=false
run_results=""

usage() {
  cat <<'EOF'
Usage: ./judging_assistance.sh [OPTIONS] ENTRY_DIR [ENWIK9]

Complete standardized technical judging:
  1. verify the native Docker security boundary before entrant code can run,
  2. calibrate this Docker environment with Geekbench 5,
  3. parse entry.env and unpack its declared source package offline,
  4. run the declared submitted decompressor artifact in its own container,
  5. install dependencies in the sole entry root/network phase,
  6. run build.sh offline to produce declared executable artifact(s),
  7. invoke the rebuilt compressor in a new container with its declared names
     offline under the formal resource limits,
  8. return and evaluate the generated archive in the host judging environment,
     and
  9. invoke the appropriate declared decompressor in another new container
     when the evaluated artifacts are not byte-identical to those qualified.

Options:
  --work-root DIR            Required filesystem with at least 100 GB free
  --geekbench-score N        Reuse a score instead of calibrating
  --results DIR              Default: ./Results
  --image NAME               Default: hutter-prize-judging:local
  --memory-limit-bytes N     Formal peak-RSS limit (default: 10 GiB)
  --cgroup-headroom-bytes N  Supervisor/cache allowance (default: 1 GiB)
  --disk-limit-bytes N       Default: 100 GB
  --disk-poll-seconds N      Default: 10
  --cpus N                   Default: 1
  --jobs N                   Concurrent long-running phases: 1 or 2 (default: 2)
  --serial                   Alias for --jobs 1, for disputed CPU timings
  --record-size N            Default: 110793128
  --expected-size N          Expected corpus bytes (default: 1000000000)
EOF
}

die() { echo "error: $*" >&2; exit 2; }
require_docker_daemon() {
  local diagnostic
  command -v docker >/dev/null \
    || die "Docker is not installed or is not in PATH"
  if diagnostic="$(docker info --format '{{.ServerVersion}}' 2>&1)"; then
    return
  fi

  if [[ "$diagnostic" == *"permission denied"* \
      || "$diagnostic" == *"Permission denied"* ]]; then
    if (( EUID != 0 )); then
      command -v sudo >/dev/null \
        || die "Docker access requires root, but sudo is not installed or is not in PATH"
      echo "Docker daemon access requires elevation; invoking sudo..." >&2
      exec sudo -- "$script_dir/judging_assistance.sh" "${original_argv[@]}"
      die "sudo could not re-execute judging_assistance.sh"
    fi
    printf 'error: root cannot access the Docker daemon:\n%s\n' "$diagnostic" >&2
  else
    printf 'error: Docker daemon is unavailable:\n%s\n' "$diagnostic" >&2
  fi
  exit 2
}
ensure_git_lfs() {
  command -v git >/dev/null \
    || die "Git is not installed or is not in PATH"
  if git lfs version >/dev/null 2>&1; then
    return
  fi

  echo "Git LFS is required; installing it with the trusted host helper..." >&2
  if (( EUID == 0 )); then
    "$script_dir/install-host-dependencies.sh"
  else
    command -v sudo >/dev/null \
      || die "Git LFS installation requires root, but sudo is not installed or is not in PATH"
    sudo -- "$script_dir/install-host-dependencies.sh"
  fi
  git lfs version >/dev/null 2>&1 \
    || die "Git LFS installation completed but 'git lfs' is unavailable"
}
require_materialized_assets() {
  local asset first_line relative include actual_sha256
  local -a assets=(
    "$script_dir/Geekbench-5.5.1-Linux.tar.gz"
    "$script_dir/UPX-5.1.1-amd64_linux.tar.xz"
    "$submission_entry_dir/$HP_SOURCE_PACKAGE"
    "$submission_entry_dir/$HP_ARCHIVE"
  )
  local -a pointers=() includes=()
  if [[ "$HP_ENTRY_FORMAT" == separate-decompressor ]]; then
    assets+=("$submission_entry_dir/$HP_DECOMPRESSOR")
  fi

  for asset in "${assets[@]}"; do
    [[ -f "$asset" && ! -L "$asset" ]] \
      || die "required artifact is missing or is not a regular file: $asset"
    first_line=
    if (( $(stat --format='%s' "$asset") <= 1024 )); then
      IFS= read -r first_line < "$asset" || true
    fi
    if [[ "$first_line" == 'version https://git-lfs.github.com/spec/v1' ]]; then
      if [[ "$asset" == "$script_dir/"* ]]; then
        relative="${asset#"$script_dir/"}"
        pointers+=("$relative")
        includes+=("$relative")
      else
        pointers+=("$asset")
      fi
    fi
  done

  if (( ${#pointers[@]} > 0 )); then
    if (( ${#pointers[@]} != ${#includes[@]} )); then
      echo "error: required Git LFS pointers outside the judging repository cannot be fetched automatically:" >&2
      for asset in "${pointers[@]}"; do
        [[ "$asset" == /* ]] && printf '  %s\n' "$asset" >&2
      done
      exit 2
    fi

    ensure_git_lfs
    include="$(IFS=,; echo "${includes[*]}")"
    echo "Materializing required Git LFS objects..." >&2
    git -C "$script_dir" lfs install --local >/dev/null
    git -C "$script_dir" lfs pull --include="$include"

    for asset in "${assets[@]}"; do
      first_line=
      if (( $(stat --format='%s' "$asset") <= 1024 )); then
        IFS= read -r first_line < "$asset" || true
      fi
      [[ "$first_line" != 'version https://git-lfs.github.com/spec/v1' ]] \
        || die "Git LFS did not materialize required artifact: $asset"
    done
  fi

  actual_sha256="$(sha256sum "$script_dir/Geekbench-5.5.1-Linux.tar.gz" \
    | awk '{print $1}')"
  [[ "$actual_sha256" == 32037e55c3dc8f360fe16b7fbb188d31387ea75980e48d8cf028330e3239c404 ]] \
    || die "Geekbench-5.5.1-Linux.tar.gz failed its pinned SHA-256 check"
  actual_sha256="$(sha256sum "$script_dir/UPX-5.1.1-amd64_linux.tar.xz" \
    | awk '{print $1}')"
  [[ "$actual_sha256" == 1ff660454227861e00772f743f66b900072116b9dc24f6ee28b97cce88a7828a ]] \
    || die "UPX-5.1.1-amd64_linux.tar.xz failed its pinned SHA-256 check"
}
cleanup_staged_entry() {
  if [[ -n "$active_stage_root" && -d "$active_stage_root" ]]; then
    docker run --rm --network none \
      --mount "type=bind,source=$active_stage_root,target=/work" \
      "$image" /usr/local/bin/clean-work >/dev/null 2>&1 || true
    rmdir -- "$active_stage_root" >/dev/null 2>&1 || true
    active_stage_root=""
  fi
}
remove_qualification_container() {
  local container_id=""
  if [[ -r "$qualification_container_file" ]]; then
    IFS= read -r container_id < "$qualification_container_file" || true
    if [[ "$container_id" =~ ^[0-9a-f]{12,64}$ ]]; then
      docker rm --force "$container_id" >/dev/null 2>&1 || true
    fi
    rm -f -- "$qualification_container_file"
  fi
}
cleanup_qualification() {
  local attempt
  remove_qualification_container
  if [[ -n "$qualification_pid" ]]; then
    kill -TERM "$qualification_pid" >/dev/null 2>&1 || true
    for ((attempt = 0; attempt < 50; attempt++)); do
      remove_qualification_container
      kill -0 "$qualification_pid" >/dev/null 2>&1 || break
      sleep 0.1
    done
    if kill -0 "$qualification_pid" >/dev/null 2>&1; then
      kill -KILL "$qualification_pid" >/dev/null 2>&1 || true
    fi
    wait "$qualification_pid" >/dev/null 2>&1 || true
    qualification_pid=""
  fi
  if [[ -n "$qualification_container_file" ]]; then
    rm -f -- "$qualification_container_file"
  fi
}
cleanup_all() {
  cleanup_qualification
  cleanup_staged_entry
  restore_invoking_user_ownership
}
restore_invoking_user_ownership() {
  local owner
  (( EUID == 0 )) || return 0
  [[ "${SUDO_UID:-}" =~ ^[0-9]+$ && "${SUDO_GID:-}" =~ ^[0-9]+$ ]] \
    || return 0
  owner="$SUDO_UID:$SUDO_GID"

  if [[ -n "$run_results" && -d "$run_results" && ! -L "$run_results" ]]; then
    chown -R -- "$owner" "$run_results" >/dev/null 2>&1 || true
  fi
  if [[ "$results_path_created" == true \
      && -d "$results_path" && ! -L "$results_path" ]]; then
    chown -- "$owner" "$results_path" >/dev/null 2>&1 || true
  fi
}
trap cleanup_all EXIT
trap 'exit 130' INT TERM

stage_fail() {
  local stage="$1"
  local reason="$2"
  {
    echo "technical_verdict=FAIL"
    echo "failed_stage=$stage"
    echo "reason=$reason"
  } > "$run_results/final.env"
  printf 'FAIL at %s: %s\nResults: %s\n' "$stage" "$reason" "$run_results" \
    | tee "$run_results/final-report.txt" >&2
  exit 1
}

declare -a positional=()
while (( $# > 0 )); do
  case "$1" in
    --work-root) (( $# >= 2 )) || die "$1 requires a value"; work_root="$2"; shift 2 ;;
    --geekbench-score) (( $# >= 2 )) || die "$1 requires a value"; geekbench_score="$2"; shift 2 ;;
    --results) (( $# >= 2 )) || die "$1 requires a value"; results_path="$2"; shift 2 ;;
    --image) (( $# >= 2 )) || die "$1 requires a value"; image="$2"; shift 2 ;;
    --memory-limit-bytes) (( $# >= 2 )) || die "$1 requires a value"; memory_limit_bytes="$2"; shift 2 ;;
    --cgroup-headroom-bytes) (( $# >= 2 )) || die "$1 requires a value"; cgroup_memory_headroom_bytes="$2"; shift 2 ;;
    --disk-limit-bytes) (( $# >= 2 )) || die "$1 requires a value"; disk_limit_bytes="$2"; shift 2 ;;
    --disk-poll-seconds) (( $# >= 2 )) || die "$1 requires a value"; disk_poll_seconds="$2"; shift 2 ;;
    --cpus) (( $# >= 2 )) || die "$1 requires a value"; cpu_limit="$2"; shift 2 ;;
    --jobs) (( $# >= 2 )) || die "$1 requires a value"; job_slots="$2"; shift 2 ;;
    --serial) job_slots=1; shift ;;
    --record-size) (( $# >= 2 )) || die "$1 requires a value"; record_size="$2"; shift 2 ;;
    --expected-size) (( $# >= 2 )) || die "$1 requires a value"; expected_size="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) positional+=("$1"); shift ;;
  esac
done
(( ${#positional[@]} == 1 || ${#positional[@]} == 2 )) \
  || die "ENTRY_DIR and optional ENWIK9 are required"
entry_dir="${positional[0]}"
(( ${#positional[@]} == 1 )) || reference_path="${positional[1]}"

for numeric_name in memory_limit_bytes cgroup_memory_headroom_bytes disk_limit_bytes disk_poll_seconds record_size expected_size; do
  value="${!numeric_name}"
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || die "$numeric_name must be a positive integer"
done
readonly cgroup_memory_ceiling_bytes="$((memory_limit_bytes + cgroup_memory_headroom_bytes))"
(( cgroup_memory_ceiling_bytes > memory_limit_bytes )) \
  || die "invalid cgroup memory ceiling"
[[ "$cpu_limit" =~ ^[0-9]+([.][0-9]+)?$ ]] \
  && awk -v n="$cpu_limit" 'BEGIN { exit !(n > 0) }' \
  || die "cpus must be positive"
[[ "$job_slots" == 1 || "$job_slots" == 2 ]] \
  || die "jobs must be 1 or 2"
[[ -z "$geekbench_score" || "$geekbench_score" =~ ^[1-9][0-9]*$ ]] \
  || die "invalid Geekbench score"
[[ -d "$entry_dir" && ! -L "$entry_dir" ]] || die "invalid entry directory: $entry_dir"
[[ -f "$reference_path" && ! -L "$reference_path" ]] || die "invalid enwik9"
[[ -n "$work_root" ]] || die "--work-root is required"
[[ -d "$work_root" && ! -L "$work_root" && -w "$work_root" ]] \
  || die "invalid or unwritable work root: $work_root"
entry_dir="$(realpath -- "$entry_dir")"
readonly submission_entry_dir="$entry_dir"
reference_path="$(realpath -- "$reference_path")"
work_root="$(realpath -- "$work_root")"
[[ "$(stat --format='%s' "$reference_path")" == "$expected_size" ]] \
  || die "enwik9 must be exactly $expected_size bytes"

hp_manifest_load "$submission_entry_dir/entry.env" || exit 2
hp_manifest_require_linux || exit 2
[[ -f "$submission_entry_dir/$HP_ARCHIVE" \
    && ! -L "$submission_entry_dir/$HP_ARCHIVE" ]] \
  || die "entry is missing declared ARCHIVE $HP_ARCHIVE"
if [[ "$HP_ENTRY_FORMAT" == separate-decompressor ]]; then
  [[ -f "$submission_entry_dir/$HP_DECOMPRESSOR" \
      && ! -L "$submission_entry_dir/$HP_DECOMPRESSOR" ]] \
    || die "entry is missing declared submitted DECOMPRESSOR $HP_DECOMPRESSOR"
fi

require_materialized_assets
require_docker_daemon

[[ -e "$results_path" ]] || results_path_created=true
mkdir -p -- "$results_path"
results_path="$(realpath -- "$results_path")"
readonly stamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
readonly entry_name="$(basename -- "$entry_dir")"
run_results="$results_path/full-$stamp-$entry_name"
readonly run_results
mkdir -p -- "$run_results/generated"
qualification_container_file="$run_results/qualification-container-id"

echo "Building the common judging image..." >&2
docker build --tag "$image" "$script_dir" >&2 \
  || stage_fail common_image "Docker image build failed"

echo "Checking the native Docker security boundary..." >&2
if ! "$script_dir/host-security-preflight.sh" \
    --image "$image" --report "$run_results/host-security.env" \
    2> >(tee "$run_results/host-security.log" >&2); then
  stage_fail host_security "required Docker confinement is not active"
fi

active_stage_root="$(mktemp -d -- "$work_root/hutter-package-$stamp.XXXXXX")"
prepared_entry="$active_stage_root/$entry_name"
if ! "$script_dir/prepare-entry.sh" \
    --skip-build --image "$image" \
    --results "$run_results/submission-package" \
    --output "$prepared_entry" "$submission_entry_dir" >/dev/null; then
  stage_fail submission_package "source package preparation failed"
fi
entry_dir="$prepared_entry"

for required in install.sh build.sh "$HP_COMPRESSOR_ARGUMENTS" entry.env; do
  [[ -f "$entry_dir/$required" && ! -L "$entry_dir/$required" ]] \
    || stage_fail submission_package "prepared package is missing regular $required"
done

hp_manifest_load "$entry_dir/entry.env" || exit 2
decompressed_output="$HP_DECOMPRESSED_OUTPUT"
command_line_bytes="$(stat --format='%s' "$entry_dir/$HP_COMPRESSOR_ARGUMENTS")"
command_line_sha256="$(sha256sum "$entry_dir/$HP_COMPRESSOR_ARGUMENTS" | awk '{print $1}')"

if [[ -z "$geekbench_score" ]]; then
  geekbench_score="$("$script_dir/benchmark.sh" \
    --skip-build --image "$image" --results "$run_results/calibration")" \
    || stage_fail geekbench "automatic calibration failed"
fi
time_limit_seconds="$(awk -v score="$geekbench_score" \
  'BEGIN { print int((70000 * 3600) / score) }')"

common_limits=(
  --geekbench-score "$geekbench_score"
  --memory-limit-bytes "$memory_limit_bytes"
  --cgroup-headroom-bytes "$cgroup_memory_headroom_bytes"
  --disk-limit-bytes "$disk_limit_bytes"
  --disk-poll-seconds "$disk_poll_seconds"
  --cpus "$cpu_limit"
  --work-root "$work_root"
  --image "$image"
  --expected-size "$expected_size"
)

mkdir -p -- "$run_results/normalized/submitted" "$run_results/normalized/rebuilt"
if [[ "$HP_ENTRY_FORMAT" == self-extracting ]]; then
  submitted_execution_dir="$run_results/normalized/submitted"
  if ! "$script_dir/normalize-executable.sh" \
      --image "$image" --format "$HP_ARCHIVE_FORMAT" \
      --results "$run_results/normalization/submitted-archive" \
      --output "$submitted_execution_dir/$HP_ARCHIVE" \
      "$submission_entry_dir/$HP_ARCHIVE" >/dev/null; then
    stage_fail submitted_normalization "declared ARCHIVE could not be normalized"
  fi
else
  submitted_execution_dir="$run_results/normalized/submitted"
  if ! "$script_dir/normalize-executable.sh" \
      --image "$image" --format "$HP_DECOMPRESSOR_FORMAT" \
      --results "$run_results/normalization/submitted-decompressor" \
      --output "$submitted_execution_dir/$HP_DECOMPRESSOR" \
      "$submission_entry_dir/$HP_DECOMPRESSOR" >/dev/null; then
    stage_fail submitted_normalization "declared DECOMPRESSOR could not be normalized"
  fi
fi

qualification_command=("$script_dir/qualify-archive.sh" --skip-build
  --container-id-file "$qualification_container_file"
  --results "$run_results/submitted-decompression"
  --output "$decompressed_output" "${common_limits[@]}")
if [[ "$HP_ENTRY_FORMAT" == self-extracting ]]; then
  qualification_command+=(--executable "$HP_ARCHIVE")
else
  qualification_command+=(
    --executable "$HP_DECOMPRESSOR"
    --arguments-file "$entry_dir/$HP_DECOMPRESSOR_ARGUMENTS"
    --payload-file "$submission_entry_dir/$HP_ARCHIVE"
    --payload-name "$HP_ARCHIVE"
  )
fi
qualification_command+=("$submitted_execution_dir" "$reference_path")

if (( job_slots == 2 )); then
  execution_mode=parallel
  echo "[$entry_name] starting submitted decompression qualification in parallel" >&2
  "${qualification_command[@]}" &
  qualification_pid=$!
else
  execution_mode=serial
  echo "[$entry_name] validating submitted decompression in serial mode" >&2
  if ! "${qualification_command[@]}"; then
    stage_fail submitted_decompression "submitted artifacts did not reproduce enwik9"
  fi
fi

compressor_path="$run_results/generated/$HP_COMPRESSOR"
decompressor_path=""
build_options=()
if [[ "$HP_ENTRY_FORMAT" == separate-decompressor ]]; then
  decompressor_path="$run_results/generated/$HP_DECOMPRESSOR"
  build_options+=(--decompressor-output "$decompressor_path")
fi
if ! "$script_dir/build-compressor.sh" \
    --skip-base-build --image "$image" \
    --work-root "$work_root" --results "$run_results/build" \
    --output "$compressor_path" "${build_options[@]}" "$entry_dir"; then
  stage_fail compressor_build "standard offline build failed"
fi

compressor_exec_path="$run_results/normalized/rebuilt/$HP_COMPRESSOR"
if ! "$script_dir/normalize-executable.sh" \
    --image "$image" --format "$HP_COMPRESSOR_FORMAT" \
    --results "$run_results/normalization/rebuilt-compressor" \
    --output "$compressor_exec_path" "$compressor_path" >/dev/null; then
  stage_fail compressor_normalization "rebuilt COMPRESSOR could not be normalized"
fi
decompressor_exec_path=""
if [[ "$HP_ENTRY_FORMAT" == separate-decompressor ]]; then
  decompressor_exec_path="$run_results/normalized/rebuilt/$HP_DECOMPRESSOR"
  if ! "$script_dir/normalize-executable.sh" \
      --image "$image" --format "$HP_DECOMPRESSOR_FORMAT" \
      --results "$run_results/normalization/rebuilt-decompressor" \
      --output "$decompressor_exec_path" "$decompressor_path" >/dev/null; then
    stage_fail decompressor_normalization "rebuilt DECOMPRESSOR could not be normalized"
  fi
fi

generated_archive="$run_results/generated/$HP_ARCHIVE"
echo "[$entry_name] starting rebuilt-compressor compression ($execution_mode mode)" >&2
if ! "$script_dir/compress-entry.sh" \
    --image "$image" --work-root "$work_root" \
    --results "$run_results/compression" \
    --output "$generated_archive" \
    --geekbench-score "$geekbench_score" \
    --memory-limit-bytes "$memory_limit_bytes" \
    --cgroup-headroom-bytes "$cgroup_memory_headroom_bytes" \
    --disk-limit-bytes "$disk_limit_bytes" \
    --disk-poll-seconds "$disk_poll_seconds" \
    --cpus "$cpu_limit" \
    --expected-size "$expected_size" \
    "$entry_dir" "$compressor_exec_path" "$reference_path"; then
  stage_fail compression "rebuilt compressor failed"
fi

if (( job_slots == 2 )); then
  echo "[$entry_name] compression finished; waiting for submitted qualification" >&2
  if wait "$qualification_pid"; then
    qualification_pid=""
  else
    qualification_exit=$?
    qualification_pid=""
    stage_fail submitted_decompression \
      "submitted artifacts did not reproduce enwik9 (exit $qualification_exit)"
  fi
fi

submitted_archive="$submission_entry_dir/$HP_ARCHIVE"
submitted_sha256="$(sha256sum "$submitted_archive" | awk '{print $1}')"
generated_sha256="$(sha256sum "$generated_archive" | awk '{print $1}')"
rebuilt_decompressor_identical=not_applicable
if [[ "$HP_ENTRY_FORMAT" == separate-decompressor ]]; then
  if cmp --silent -- "$submission_entry_dir/$HP_DECOMPRESSOR" "$decompressor_path"; then
    rebuilt_decompressor_identical=yes
  else
    rebuilt_decompressor_identical=no
  fi
fi
if cmp --silent -- "$submitted_archive" "$generated_archive"; then
  archives_identical=yes
else
  archives_identical=no
fi
if [[ "$archives_identical" == yes \
    && "$rebuilt_decompressor_identical" != no ]]; then
  second_decompression=skipped_identical
  echo "[$entry_name] generated archive is byte-identical; second decompression skipped" >&2
else
  second_decompression=required
  echo "[$entry_name] generated artifacts require a fresh decompression" >&2
  generated_qualification=("$script_dir/qualify-archive.sh" --skip-build
    --results "$run_results/generated-decompression"
    --output "$decompressed_output" "${common_limits[@]}")
  if [[ "$HP_ENTRY_FORMAT" == self-extracting ]]; then
    generated_execution_dir="$run_results/normalized/generated-archive"
    mkdir -p -- "$generated_execution_dir"
    if ! "$script_dir/normalize-executable.sh" \
        --image "$image" --format "$HP_ARCHIVE_FORMAT" \
        --results "$run_results/normalization/generated-archive" \
        --output "$generated_execution_dir/$HP_ARCHIVE" \
        "$generated_archive" >/dev/null; then
      stage_fail generated_normalization "generated ARCHIVE could not be normalized"
    fi
    generated_qualification+=(--executable "$HP_ARCHIVE")
    generated_qualification_dir="$generated_execution_dir"
  else
    generated_qualification+=(
      --executable "$HP_DECOMPRESSOR"
      --arguments-file "$entry_dir/$HP_DECOMPRESSOR_ARGUMENTS"
      --payload-file "$generated_archive"
      --payload-name "$HP_ARCHIVE"
    )
    generated_qualification_dir="$run_results/normalized/rebuilt"
  fi
  generated_qualification+=("$generated_qualification_dir" "$reference_path")
  if ! "${generated_qualification[@]}"; then
    stage_fail generated_decompression "differing generated archive did not reproduce enwik9"
  fi
  second_decompression=pass
fi

compressor_bytes="$(stat --format='%s' "$compressor_path")"
generated_archive_bytes="$(stat --format='%s' "$generated_archive")"
submitted_archive_bytes="$(stat --format='%s' "$submitted_archive")"
decompressor_bytes=0
decompressor_multiplier=0
decompressor_command_line_bytes=0
if [[ "$HP_ENTRY_FORMAT" == separate-decompressor ]]; then
  decompressor_bytes="$(stat --format='%s' "$decompressor_path")"
  decompressor_command_line_bytes="$(stat --format='%s' "$entry_dir/$HP_DECOMPRESSOR_ARGUMENTS")"
  if cmp --silent -- "$compressor_path" "$decompressor_path"; then
    decompressor_multiplier=1
  else
    decompressor_multiplier=2
  fi
fi
formal_total_bytes="$((compressor_bytes + generated_archive_bytes + command_line_bytes \
  + decompressor_multiplier * decompressor_bytes + decompressor_command_line_bytes))"
threshold_bytes="$(awk -v record="$record_size" 'BEGIN { print int(record * 0.99) }')"
improvement_percent="$(awk -v total="$formal_total_bytes" -v record="$record_size" \
  'BEGIN { printf "%.6f", 100 * (record - total) / record }')"
if (( formal_total_bytes <= threshold_bytes )); then
  record_status=MEETS_ONE_PERCENT
else
  record_status=DOES_NOT_MEET_ONE_PERCENT
fi

{
  echo "technical_verdict=PASS"
  echo "record_status=$record_status"
  echo "entry=$entry_name"
  echo "geekbench5_score=$geekbench_score"
  echo "time_limit_seconds=$time_limit_seconds"
  echo "memory_limit_bytes=$memory_limit_bytes"
  echo "cgroup_memory_headroom_bytes=$cgroup_memory_headroom_bytes"
  echo "cgroup_memory_ceiling_bytes=$cgroup_memory_ceiling_bytes"
  echo "disk_limit_bytes=$disk_limit_bytes"
  echo "job_slots=$job_slots"
  echo "execution_mode=$execution_mode"
  echo "entry_format=$HP_ENTRY_FORMAT"
  echo "execution_platform=$HP_EXECUTION_PLATFORM"
  echo "archives_identical=$archives_identical"
  echo "second_decompression=$second_decompression"
  echo "rebuilt_decompressor_identical=$rebuilt_decompressor_identical"
  echo "submitted_archive_bytes=$submitted_archive_bytes"
  echo "submitted_archive_sha256=$submitted_sha256"
  echo "generated_archive_bytes=$generated_archive_bytes"
  echo "generated_archive_sha256=$generated_sha256"
  echo "compressor_bytes=$compressor_bytes"
  echo "decompressor_bytes=$decompressor_bytes"
  echo "decompressor_multiplier=$decompressor_multiplier"
  echo "command_line_bytes=$command_line_bytes"
  echo "command_line_sha256=$command_line_sha256"
  echo "decompressor_command_line_bytes=$decompressor_command_line_bytes"
  echo "formal_total_bytes=$formal_total_bytes"
  echo "previous_record_bytes=$record_size"
  echo "one_percent_threshold_bytes=$threshold_bytes"
  echo "improvement_percent=$improvement_percent"
  echo "judging_image_id=$(docker image inspect "$image" --format '{{.Id}}')"
} > "$run_results/final.env"

{
  echo "Technical verdict: PASS"
  echo "Record threshold: $record_status"
  echo "Generated/submitted archives identical: $archives_identical"
  echo "Second generated-archive decompression: $second_decompression"
  echo "Formal size S: $formal_total_bytes bytes"
  echo "  rebuilt compressor: $compressor_bytes"
  if [[ "$HP_ENTRY_FORMAT" == separate-decompressor ]]; then
    echo "  rebuilt decompressor: $decompressor_multiplier x $decompressor_bytes"
    echo "  decompressor command-line options: $decompressor_command_line_bytes"
  fi
  echo "  generated archive: $generated_archive_bytes"
  echo "  command-line options: $command_line_bytes"
  echo "Improvement over $record_size: $improvement_percent%"
  echo "Geekbench 5 T: $geekbench_score; limit per executable: ${time_limit_seconds}s"
  echo "RAM peak-RSS limit: $(hp_format_gib "$memory_limit_bytes")"
  echo "Cgroup ceiling: $(hp_format_gib "$cgroup_memory_ceiling_bytes")"
  echo "Disk: $(hp_format_gb "$disk_limit_bytes")"
  echo "Execution mode: $execution_mode ($job_slots long-running job slots)"
  echo "Results: $run_results"
} | tee "$run_results/final-report.txt"
