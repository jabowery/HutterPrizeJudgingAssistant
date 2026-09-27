#!/usr/bin/env bash
set -Eeuo pipefail

# Trusted, repeatable comparison of native file access with the exact
# bind-mounted Docker path used for entrant work files.  This never executes
# entrant material.
readonly script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/lib/host-dependencies.sh"
source "$script_dir/lib/cold-cache.sh"

image=""
work_root=""
results=""
duration=20
size=1073741824
original_argv=("$@")

usage() {
  cat <<'EOF'
Usage: ./storage-preflight.sh --image IMAGE --work-root DIR --results DIR [OPTIONS]

Measure trusted fio workloads directly on the selected work filesystem and
through the judging system's bind-mounted Docker path.  The report records
raw fio JSON plus host/container median and p99 latency ratios. No entrant
artifact is read or executed.

Options:
  --image IMAGE       Built common judging image containing the pinned fio profile
  --work-root DIR     Filesystem used for entrant temporary work
  --results DIR       Destination for the evidence directory
  --duration SECONDS  Per-workload measurement duration (default: 20)
  --size BYTES        Prepared test-file size (default: 1073741824)
  -h, --help          Show this help
EOF
}

die() { echo "error: $*" >&2; exit 2; }
usage_error() { echo "error: $*" >&2; echo >&2; usage >&2; exit 2; }

while (( $# > 0 )); do
  case "$1" in
    --image) (( $# >= 2 )) || usage_error "$1 requires a value"; image="$2"; shift 2 ;;
    --work-root) (( $# >= 2 )) || usage_error "$1 requires a value"; work_root="$2"; shift 2 ;;
    --results) (( $# >= 2 )) || usage_error "$1 requires a value"; results="$2"; shift 2 ;;
    --duration) (( $# >= 2 )) || usage_error "$1 requires a value"; duration="$2"; shift 2 ;;
    --size) (( $# >= 2 )) || usage_error "$1 requires a value"; size="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage_error "unknown option: $1" ;;
  esac
done
[[ -n "$image" && -n "$work_root" && -n "$results" ]] || usage_error "--image, --work-root, and --results are required"
[[ "$duration" =~ ^[1-9][0-9]*$ ]] || usage_error "--duration must be a positive integer"
[[ "$size" =~ ^[1-9][0-9]*$ ]] || usage_error "--size must be a positive integer"

hp_host_dependencies_ensure "$script_dir" || exit 2
command -v fio >/dev/null || die "trusted host fio is unavailable after dependency setup"
command -v jq >/dev/null || die "trusted host jq is unavailable after dependency setup"
hp_cold_cache_acquire_lock "$script_dir" || exit 2
if ! docker info --format '{{.ServerVersion}}' >/dev/null 2>&1; then
  if (( EUID != 0 )) && command -v sudo >/dev/null; then
    echo "Docker daemon access requires elevation; invoking sudo..." >&2
    exec sudo -- "$script_dir/storage-preflight.sh" "${original_argv[@]}"
  fi
  die "Docker daemon is unavailable"
fi
[[ -d "$work_root" && ! -L "$work_root" && -w "$work_root" ]] || die "invalid work root: $work_root"
mkdir -p -- "$results"
results="$(realpath -- "$results")"
work_root="$(realpath -- "$work_root")"
report_dir="$results/storage-preflight"
rm -rf -- "$report_dir"
mkdir -p -- "$report_dir"
work_dir="$(mktemp -d -- "$work_root/hutter-storage-preflight.XXXXXX")"
trap 'rm -rf -- "$work_dir"' EXIT
target="$work_dir/fio-data"

# Populate real blocks once using direct I/O, then each measured profile starts
# from the same file. The direct profile isolates device latency; the mmap
# profile exposes page-cache/file-backed behavior relevant to PPMd models.
fio --name=prepare --filename="$target" --size="$size" --rw=write --bs=1M \
  --ioengine=psync --direct=1 --end_fsync=1 --output="$report_dir/prepare.json" \
  --output-format=json >/dev/null

run_host() {
  local profile="$1" output="$2"
  fio --name="$profile" --filename="$target" --size="$size" --rw="$3" --bs=4k \
    --ioengine="$4" --iodepth=1 --direct="$5" --time_based --runtime="$duration" \
    --randrepeat=1 --norandommap=1 --group_reporting --output="$output" \
    --output-format=json >/dev/null
}
run_container() {
  local profile="$1" output="$2"
  docker run --rm --network none --read-only --cpus 1 --memory 17179869184 \
    --cap-drop ALL --security-opt no-new-privileges=true \
    --mount "type=bind,source=$work_dir,target=/work" "$image" \
    fio --name="$profile" --filename=/work/fio-data --size="$size" --rw="$3" --bs=4k \
      --ioengine="$4" --iodepth=1 --direct="$5" --time_based --runtime="$duration" \
      --randrepeat=1 --norandommap=1 --group_reporting --output=/work/"$(basename -- "$output")" \
      --output-format=json >/dev/null
  mv -- "$work_dir/$(basename -- "$output")" "$output"
}
evict_file_cache() {
  local label="$1"
  if (( EUID == 0 )); then
    "$script_dir/cold-cache-host-helper.sh" --target "$target" \
      > "$report_dir/cache-eviction-$label.env"
  else
    sudo -- "$script_dir/cold-cache-host-helper.sh" --target "$target" \
      > "$report_dir/cache-eviction-$label.env"
  fi
}

run_host direct-host "$report_dir/direct-host.json" randread psync 1
run_container direct-container "$report_dir/direct-container.json" randread psync 1
evict_file_cache mmap-host
run_host mmap-host "$report_dir/mmap-host.json" randrw mmap 0
evict_file_cache mmap-container
run_container mmap-container "$report_dir/mmap-container.json" randrw mmap 0

latency_ns() {
  local file="$1" direction="$2" percentile="$3"
  jq -r --arg d "$direction" --arg p "$percentile" \
    '.jobs[0][$d].clat_ns.percentile[$p] // .jobs[0][$d].lat_ns.percentile[$p] // empty' "$file"
}
ratio() { awk -v c="$1" -v h="$2" 'BEGIN { if (h > 0) printf "%.6f", c / h; else print "unavailable" }'; }
direct_host_p50="$(latency_ns "$report_dir/direct-host.json" read 50.000000)"
direct_container_p50="$(latency_ns "$report_dir/direct-container.json" read 50.000000)"
direct_host_p99="$(latency_ns "$report_dir/direct-host.json" read 99.000000)"
direct_container_p99="$(latency_ns "$report_dir/direct-container.json" read 99.000000)"
mmap_host_p50="$(latency_ns "$report_dir/mmap-host.json" read 50.000000)"
mmap_container_p50="$(latency_ns "$report_dir/mmap-container.json" read 50.000000)"
mmap_host_p99="$(latency_ns "$report_dir/mmap-host.json" read 99.000000)"
mmap_container_p99="$(latency_ns "$report_dir/mmap-container.json" read 99.000000)"
{
  echo 'profile_version=1'
  echo "image=$image"
  echo "work_root=$work_root"
  echo "filesystem=$(findmnt --noheadings --output FSTYPE --target "$work_root" | awk 'NR == 1 {print $1}')"
  echo "source=$(findmnt --noheadings --output SOURCE --target "$work_root" | awk 'NR == 1 {print $1}')"
  echo "docker_storage_driver=$(docker info --format '{{.Driver}}')"
  echo "host_fio_version=$(fio --version)"
  echo "container_fio_version=$(docker run --rm --network none "$image" fio --version)"
  echo "duration_seconds=$duration"
  echo "file_size_bytes=$size"
  for profile in direct mmap; do
    for percentile in p50 p99; do
      host_var="${profile}_host_${percentile}"; container_var="${profile}_container_${percentile}"
      printf '%s_host_read_%s_ns=%s\n' "$profile" "$percentile" "${!host_var}"
      printf '%s_container_read_%s_ns=%s\n' "$profile" "$percentile" "${!container_var}"
      printf '%s_container_to_host_read_%s_ratio=%s\n' "$profile" "$percentile" "$(ratio "${!container_var}" "${!host_var}")"
    done
  done
} > "$report_dir/summary.env"

cat "$report_dir/summary.env"
