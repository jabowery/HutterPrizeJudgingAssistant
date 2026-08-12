#!/usr/bin/env bash
set -Eeuo pipefail

readonly script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
image=hutter-prize-judge:local
artifact_format=""
output_path=""
results_path="$script_dir/Results"
artifact_path=""
active_output_dir=""

usage() {
  cat <<'EOF'
Usage: ./normalize-executable.sh --format FORMAT --output FILE [OPTIONS] ARTIFACT

Convert a declared executable artifact into the exact binary that will be
executed. FORMAT is executable, upx, or upx-overlay. The latter preserves data
appended to a UPX-packed executable prefix. Normalization occurs offline as UID
65532 in a dedicated container. The result is returned to the host, where its
size, hash, and file type are recorded before any execution container sees it.

Options:
  --format FORMAT   executable, upx, or upx-overlay
  --output FILE     Required normalized executable destination
  --results DIR     Evidence directory (default: ./Results)
  --image NAME      Judge image (default: hutter-prize-judge:local)
EOF
}

die() { echo "error: $*" >&2; exit 2; }
cleanup() {
  if [[ -n "$active_output_dir" && -d "$active_output_dir" ]]; then
    docker run --rm --network none \
      --mount "type=bind,source=$active_output_dir,target=/work" \
      "$image" /usr/local/bin/clean-work >/dev/null 2>&1 || true
    rmdir -- "$active_output_dir" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

while (( $# > 0 )); do
  case "$1" in
    --format) (( $# >= 2 )) || die "$1 requires a value"; artifact_format="$2"; shift 2 ;;
    --output) (( $# >= 2 )) || die "$1 requires a value"; output_path="$2"; shift 2 ;;
    --results) (( $# >= 2 )) || die "$1 requires a value"; results_path="$2"; shift 2 ;;
    --image) (( $# >= 2 )) || die "$1 requires a value"; image="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) [[ -z "$artifact_path" ]] || die "only one ARTIFACT may be supplied"; artifact_path="$1"; shift ;;
  esac
done

[[ "$artifact_format" == executable || "$artifact_format" == upx \
    || "$artifact_format" == upx-overlay ]] \
  || die "--format must be executable, upx, or upx-overlay"
[[ -n "$output_path" ]] || die "--output is required"
[[ -f "$artifact_path" && ! -L "$artifact_path" ]] || die "invalid ARTIFACT"
[[ ! -e "$output_path" && ! -L "$output_path" ]] || die "output already exists: $output_path"
docker image inspect "$image" >/dev/null || die "missing image: $image"

artifact_path="$(realpath -- "$artifact_path")"
mkdir -p -- "$(dirname -- "$output_path")" "$results_path"
output_path="$(realpath --canonicalize-missing -- "$output_path")"
results_path="$(realpath -- "$results_path")"
readonly stamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
readonly result_dir="$results_path/$stamp/normalize-$(basename -- "$artifact_path")"
mkdir -p -- "$result_dir"
active_output_dir="$(mktemp -d)"
chmod 0777 "$active_output_dir"

docker run --rm --network none --read-only \
  --memory 2147483648 --memory-swap 2147483648 --pids-limit 256 \
  --cap-drop ALL --security-opt no-new-privileges=true --user 65532:65532 \
  --mount "type=bind,source=$artifact_path,target=/submission/artifact,readonly" \
  --mount "type=bind,source=$active_output_dir,target=/output" \
  --env "ARTIFACT_FORMAT=$artifact_format" \
  --env "OUTPUT_NAME=$(basename -- "$output_path")" \
  "$image" /usr/local/bin/normalize-executable \
  >"$result_dir/stdout.log" 2>"$result_dir/stderr.log"

normalized="$active_output_dir/$(basename -- "$output_path")"
[[ -f "$normalized" && ! -L "$normalized" && -x "$normalized" ]] \
  || die "normalization did not return a regular executable"
cp --reflink=never -- "$normalized" "$output_path"
chmod 0555 "$output_path"

{
  echo "artifact_format=$artifact_format"
  echo "submitted_path=$artifact_path"
  echo "submitted_bytes=$(stat --format='%s' "$artifact_path")"
  echo "submitted_sha256=$(sha256sum "$artifact_path" | awk '{print $1}')"
  echo "normalized_path=$output_path"
  echo "normalized_bytes=$(stat --format='%s' "$output_path")"
  echo "normalized_sha256=$(sha256sum "$output_path" | awk '{print $1}')"
  echo "normalized_file_type=$(file --brief -- "$output_path")"
  echo "normalization_network=none"
  echo "normalization_uid=65532"
} > "$result_dir/normalization.env"

printf '%s\n' "$output_path"
