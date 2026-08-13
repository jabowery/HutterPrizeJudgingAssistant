#!/usr/bin/env bash
set -Eeuo pipefail

readonly script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/lib/entry-env.sh"
image=hutter-prize-judging:local
entry_dir=""
output_dir=""
results_path="$script_dir/Results"
skip_build=false
prepared_success=false
output_created=false

cleanup_output() {
  if [[ "$prepared_success" != true && "$output_created" == true \
      && -n "$output_dir" \
      && -d "$output_dir" && ! -L "$output_dir" ]]; then
    docker run --rm --network none \
      --mount "type=bind,source=$output_dir,target=/work" \
      "$image" /usr/local/bin/clean-work >/dev/null 2>&1 || true
    rmdir -- "$output_dir" >/dev/null 2>&1 || true
  fi
}
trap cleanup_output EXIT
trap 'exit 130' INT TERM

usage() {
  cat <<'EOF'
Usage: ./prepare-entry.sh [OPTIONS] ENTRY_DIR

Safely unpack the source package named by ENTRY_DIR/entry.env. The package
must contain one top-level directory holding install.sh, build.sh, the declared
argument file(s), and the complete source. The normalized prepared directory
is printed on stdout. No filename is inferred by the orchestrator.

Options:
  --output DIR       Required new directory for prepared source
  --results DIR      Store preparation evidence under DIR (default: ./Results)
  --image NAME       Common judging image (default: hutter-prize-judging:local)
  --skip-build       Reuse the common judging image
EOF
}

die() { echo "error: $*" >&2; exit 2; }

while (( $# > 0 )); do
  case "$1" in
    --output) (( $# >= 2 )) || die "$1 requires a value"; output_dir="$2"; shift 2 ;;
    --results) (( $# >= 2 )) || die "$1 requires a value"; results_path="$2"; shift 2 ;;
    --image) (( $# >= 2 )) || die "$1 requires a value"; image="$2"; shift 2 ;;
    --skip-build) skip_build=true; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) [[ -z "$entry_dir" ]] || die "only one ENTRY_DIR may be supplied"; entry_dir="$1"; shift ;;
  esac
done

[[ -n "$entry_dir" ]] || die "ENTRY_DIR is required"
[[ -n "$output_dir" ]] || die "--output is required"
[[ -d "$entry_dir" && ! -L "$entry_dir" ]] || die "invalid entry directory: $entry_dir"
[[ ! -e "$output_dir" && ! -L "$output_dir" ]] || die "output already exists: $output_dir"
entry_dir="$(realpath -- "$entry_dir")"
hp_manifest_load "$entry_dir/entry.env" || exit 2
hp_manifest_require_linux || exit 2
readonly package="$entry_dir/$HP_SOURCE_PACKAGE"
[[ -f "$package" && ! -L "$package" ]] \
  || die "SOURCE_PACKAGE is missing or is not a regular file: $HP_SOURCE_PACKAGE"
[[ -f "$entry_dir/$HP_ARCHIVE" && ! -L "$entry_dir/$HP_ARCHIVE" ]] \
  || die "ARCHIVE is missing or is not a regular file: $HP_ARCHIVE"
if [[ "$HP_ENTRY_FORMAT" == separate-decompressor ]]; then
  [[ -f "$entry_dir/$HP_DECOMPRESSOR" && ! -L "$entry_dir/$HP_DECOMPRESSOR" ]] \
    || die "submitted DECOMPRESSOR is missing or invalid: $HP_DECOMPRESSOR"
fi

command -v docker >/dev/null || die "docker is not installed"
if [[ "$skip_build" == true ]]; then
  docker image inspect "$image" >/dev/null || die "missing image: $image"
else
  docker build --tag "$image" "$script_dir" >&2
fi

mkdir -p -- "$(dirname -- "$output_dir")"
mkdir -- "$output_dir"
output_created=true
chmod 0777 "$output_dir"
output_dir="$(realpath -- "$output_dir")"

echo "[$(basename -- "$entry_dir")] unpacking $(basename -- "$package") offline as UID 65532" >&2
if ! docker run --rm \
    --network none \
    --read-only \
    --memory 2147483648 \
    --memory-swap 2147483648 \
    --pids-limit 256 \
    --cap-drop ALL \
    --security-opt no-new-privileges=true \
    --user 65532:65532 \
    --mount "type=bind,source=$package,target=/submission/package,readonly" \
    --mount "type=bind,source=$output_dir,target=/entry" \
    "$image" /usr/local/bin/prepare-entry; then
  docker run --rm --network none \
    --mount "type=bind,source=$output_dir,target=/work" \
    "$image" /usr/local/bin/clean-work >/dev/null 2>&1 || true
  rmdir -- "$output_dir" >/dev/null 2>&1 || true
  die "submission package preparation failed"
fi
chmod 0755 "$output_dir"

for required in install.sh build.sh "$HP_COMPRESSOR_ARGUMENTS"; do
  [[ -f "$output_dir/$required" && ! -L "$output_dir/$required" ]] \
    || die "prepared source is missing regular $required"
done
hp_arguments_validate "$output_dir/$HP_COMPRESSOR_ARGUMENTS" COMPRESSOR_ARGUMENTS \
  || exit 2
if [[ "$HP_ENTRY_FORMAT" == separate-decompressor ]]; then
  [[ -f "$output_dir/$HP_DECOMPRESSOR_ARGUMENTS" \
      && ! -L "$output_dir/$HP_DECOMPRESSOR_ARGUMENTS" ]] \
    || die "prepared source is missing regular $HP_DECOMPRESSOR_ARGUMENTS"
  hp_arguments_validate "$output_dir/$HP_DECOMPRESSOR_ARGUMENTS" \
    DECOMPRESSOR_ARGUMENTS || exit 2
fi
cp --reflink=never -- "$entry_dir/entry.env" "$output_dir/entry.env"
chmod 0444 "$output_dir/entry.env"

mkdir -p -- "$results_path"
results_path="$(realpath -- "$results_path")"
readonly stamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
readonly result_dir="$results_path/$stamp/package-$(basename -- "$entry_dir")"
mkdir -p -- "$result_dir/scripts"

for file in install.sh build.sh "$HP_COMPRESSOR_ARGUMENTS" entry.env; do
  cp --reflink=never -- "$output_dir/$file" "$result_dir/scripts/$file"
done
if [[ "$HP_ENTRY_FORMAT" == separate-decompressor ]]; then
  cp --reflink=never -- "$output_dir/$HP_DECOMPRESSOR_ARGUMENTS" \
    "$result_dir/scripts/$HP_DECOMPRESSOR_ARGUMENTS"
fi
chmod 0444 "$result_dir/scripts/"*

{
  echo "entry=$(basename -- "$entry_dir")"
  echo "package_file=$(basename -- "$package")"
  echo "package_bytes=$(stat --format='%s' "$package")"
  echo "package_sha256=$(sha256sum "$package" | awk '{print $1}')"
  echo "entry_format=$HP_ENTRY_FORMAT"
  echo "execution_platform=$HP_EXECUTION_PLATFORM"
  echo "archive_file=$HP_ARCHIVE"
  echo "archive_bytes=$(stat --format='%s' "$entry_dir/$HP_ARCHIVE")"
  echo "archive_sha256=$(sha256sum "$entry_dir/$HP_ARCHIVE" | awk '{print $1}')"
  echo "preparation_network=none"
  echo "preparation_uid=65532"
  echo "judging_image=$image"
  echo "judging_image_id=$(docker image inspect "$image" --format '{{.Id}}')"
} > "$result_dir/package.env"

find -P "$output_dir" -mindepth 1 -printf '%y\t%P\t%s\n' \
  | sort > "$result_dir/package-members.tsv"
prepared_success=true
printf '%s\n' "$output_dir"
