#!/usr/bin/env bash
set -Eeuo pipefail

readonly script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/lib/entry-env.sh"
source "$script_dir/lib/resource-units.sh"
base_image=hutter-prize-judging:local
entry_dir=""
output_path=""
decompressor_output_path=""
results_path="$script_dir/Results"
work_root="${TMPDIR:-/tmp}"
skip_base_build=false
active_container=""
active_work_dir=""

usage() {
  cat <<'EOF'
Usage: ./build-compressor.sh [OPTIONS] ENTRY_DIR

Build the executable artifact(s) declared by ENTRY_DIR/entry.env. install.sh is
executed as root with network access only while making an isolated dependency
image. build.sh then runs offline and unprivileged in a different container.

Options:
  --output FILE       Copy the declared COMPRESSOR to FILE
  --decompressor-output FILE
                      Copy the declared DECOMPRESSOR to FILE (relaxed form)
  --results DIR       Store build evidence under DIR (default: ./Results)
  --work-root DIR     Filesystem for temporary build data (default: $TMPDIR)
  --image NAME        Base judging image (default: hutter-prize-judging:local)
  --skip-base-build   Reuse the base judging image
EOF
}

die() { echo "error: $*" >&2; exit 2; }
cleanup() {
  [[ -z "$active_container" ]] || docker rm --force "$active_container" >/dev/null 2>&1 || true
  if [[ -n "$active_work_dir" && -d "$active_work_dir" ]]; then
    docker run --rm --network none \
      --mount "type=bind,source=$active_work_dir,target=/work" \
      "$base_image" /usr/local/bin/clean-work >/dev/null 2>&1 || true
    rmdir -- "$active_work_dir" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

while (( $# > 0 )); do
  case "$1" in
    --output) (( $# >= 2 )) || die "$1 requires a value"; output_path="$2"; shift 2 ;;
    --decompressor-output)
      (( $# >= 2 )) || die "$1 requires a value"
      decompressor_output_path="$2"
      shift 2
      ;;
    --results) (( $# >= 2 )) || die "$1 requires a value"; results_path="$2"; shift 2 ;;
    --work-root) (( $# >= 2 )) || die "$1 requires a value"; work_root="$2"; shift 2 ;;
    --image) (( $# >= 2 )) || die "$1 requires a value"; base_image="$2"; shift 2 ;;
    --skip-base-build) skip_base_build=true; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) [[ -z "$entry_dir" ]] || die "only one ENTRY_DIR may be supplied"; entry_dir="$1"; shift ;;
  esac
done

[[ -n "$entry_dir" ]] || die "ENTRY_DIR is required"
[[ -d "$entry_dir" && ! -L "$entry_dir" ]] || die "invalid entry directory: $entry_dir"
entry_dir="$(realpath -- "$entry_dir")"
hp_manifest_load "$entry_dir/entry.env" || exit 2
hp_manifest_require_linux || exit 2
for required in install.sh build.sh; do
  [[ -f "$entry_dir/$required" && ! -L "$entry_dir/$required" ]] \
    || die "entry is missing regular $required"
done
[[ -d "$work_root" && ! -L "$work_root" && -w "$work_root" ]] \
  || die "invalid or unwritable work root: $work_root"
work_root="$(realpath -- "$work_root")"
command -v docker >/dev/null || die "docker is not installed"

if [[ "$skip_base_build" == true ]]; then
  docker image inspect "$base_image" >/dev/null || die "missing image: $base_image"
else
  docker build --tag "$base_image" "$script_dir" >&2
fi

entry_name="$(basename -- "$entry_dir")"
install_hash="$(sha256sum "$entry_dir/install.sh" | awk '{print $1}')"
safe_name="$(printf '%s' "$entry_name" | tr -c 'a-zA-Z0-9_.-' '-' | tr '[:upper:]' '[:lower:]')"
dependency_image="hutter-prize-entry-${safe_name}:${install_hash:0:16}"

mkdir -p -- "$results_path"
results_path="$(realpath -- "$results_path")"
readonly stamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
readonly result_dir="$results_path/$stamp/build-$entry_name"
mkdir -p -- "$result_dir"

echo "[$entry_name] building dependency image; this is the only entry root/network phase" >&2
readonly max_install_attempts=3
install_attempts=0
install_exit=1
: > "$result_dir/install.log"
while (( install_attempts < max_install_attempts )); do
  ((install_attempts += 1))
  echo "[$entry_name] dependency image attempt $install_attempts/$max_install_attempts" \
    | tee -a "$result_dir/install.log" >&2
  set +e
  docker build \
    --file "$script_dir/docker/EntryDependencies.Dockerfile" \
    --build-arg "BASE_IMAGE=$base_image" \
    --tag "$dependency_image" \
    "$entry_dir" 2>&1 | tee -a "$result_dir/install.log" >&2
  install_exit="${PIPESTATUS[0]}"
  set -e
  (( install_exit != 0 )) || break
  if (( install_attempts < max_install_attempts )); then
    retry_delay="$((install_attempts * 20))"
    echo "[$entry_name] dependency image failed with status $install_exit; retrying in $(hp_format_hms "$retry_delay")" \
      | tee -a "$result_dir/install.log" >&2
    sleep "$retry_delay"
  fi
done
(( install_exit == 0 )) || die "install.sh dependency image failed with status $install_exit"

active_work_dir="$(mktemp -d -- "$work_root/hutter-build-$stamp.XXXXXX")"
chmod 1777 "$active_work_dir"
mkdir -p -- "$active_work_dir/run/tmp"
chmod 1777 "$active_work_dir/run/tmp"
active_container="$(docker create \
  --network none \
  --read-only \
  --memory 10737418240 \
  --memory-swap 10737418240 \
  --pids-limit 16384 \
  --ulimit nofile=65536:65536 \
  --cap-drop ALL \
  --security-opt no-new-privileges=true \
  --user 65532:65532 \
  --workdir /work \
  --mount "type=bind,source=$entry_dir,target=/entry,readonly" \
  --mount "type=bind,source=$active_work_dir,target=/work" \
  "$dependency_image" /entry/build.sh)"

echo "[$entry_name] running build.sh offline as UID 65532" >&2
docker start --attach "$active_container" \
  > >(tee "$result_dir/stdout.log" >&2) \
  2> >(tee "$result_dir/stderr.log" >&2) || build_exit=$?
build_exit="${build_exit:-0}"
docker inspect "$active_container" > "$result_dir/container-inspect.json"
(( build_exit == 0 )) || die "build.sh failed with status $build_exit"
[[ -f "$active_work_dir/$HP_COMPRESSOR" && ! -L "$active_work_dir/$HP_COMPRESSOR" ]] \
  || die "build.sh did not produce declared COMPRESSOR ./$HP_COMPRESSOR"
if [[ "$HP_ENTRY_FORMAT" == separate-decompressor ]]; then
  [[ -f "$active_work_dir/$HP_DECOMPRESSOR" \
      && ! -L "$active_work_dir/$HP_DECOMPRESSOR" ]] \
    || die "build.sh did not produce declared DECOMPRESSOR ./$HP_DECOMPRESSOR"
fi

if [[ -z "$output_path" ]]; then
  output_path="$result_dir/$HP_COMPRESSOR"
fi
mkdir -p -- "$(dirname -- "$output_path")"
cp --reflink=never -- "$active_work_dir/$HP_COMPRESSOR" "$output_path"
chmod 0555 "$output_path"
output_path="$(realpath -- "$output_path")"

if [[ "$HP_ENTRY_FORMAT" == separate-decompressor ]]; then
  if [[ -z "$decompressor_output_path" ]]; then
    decompressor_output_path="$result_dir/$HP_DECOMPRESSOR"
  fi
  mkdir -p -- "$(dirname -- "$decompressor_output_path")"
  cp --reflink=never -- "$active_work_dir/$HP_DECOMPRESSOR" \
    "$decompressor_output_path"
  chmod 0555 "$decompressor_output_path"
  decompressor_output_path="$(realpath -- "$decompressor_output_path")"
fi

{
  echo "entry=$entry_name"
  echo "install_sha256=$install_hash"
  echo "install_attempts=$install_attempts"
  echo "install_max_attempts=$max_install_attempts"
  echo "build_sha256=$(sha256sum "$entry_dir/build.sh" | awk '{print $1}')"
  echo "dependency_image=$dependency_image"
  echo "dependency_image_id=$(docker image inspect "$dependency_image" --format '{{.Id}}')"
  echo "build_network=none"
  echo "build_uid=65532"
  echo "compressor_name=$HP_COMPRESSOR"
  echo "compressor_path=$output_path"
  echo "compressor_bytes=$(stat --format='%s' "$output_path")"
  echo "compressor_sha256=$(sha256sum "$output_path" | awk '{print $1}')"
  if [[ "$HP_ENTRY_FORMAT" == separate-decompressor ]]; then
    echo "decompressor_name=$HP_DECOMPRESSOR"
    echo "decompressor_path=$decompressor_output_path"
    echo "decompressor_bytes=$(stat --format='%s' "$decompressor_output_path")"
    echo "decompressor_sha256=$(sha256sum "$decompressor_output_path" | awk '{print $1}')"
  fi
} > "$result_dir/build.env"

docker rm "$active_container" >/dev/null
active_container=""
printf '%s\n' "$output_path"
