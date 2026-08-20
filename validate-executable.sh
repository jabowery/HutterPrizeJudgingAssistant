#!/usr/bin/env bash
set -Eeuo pipefail

readonly script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
image=hutter-prize-judging:local
artifact_format=""
output_path=""
results_path="$script_dir/Results"
artifact_path=""
active_output_dir=""

usage() {
  cat <<'EOF'
Usage: ./validate-executable.sh --format FORMAT --output FILE [OPTIONS] ARTIFACT

Validate a declared executable artifact and stage the exact same bytes for
execution. FORMAT is executable, upx, or upx-overlay. UPX validation unpacks a
scratch copy offline as UID 65532 in a dedicated container, but the scratch
copy is never executed. The original artifact is returned unchanged to the
host, where its size, hash, and file type are recorded before execution.

Options:
  --format FORMAT   executable, upx, or upx-overlay
  --output FILE     Required validated execution-copy destination
  --results DIR     Evidence directory (default: ./Results)
  --image NAME      Judging image (default: hutter-prize-judging:local)
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
readonly result_dir="$results_path/$stamp/validate-$(basename -- "$artifact_path")"
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
  "$image" /usr/local/bin/validate-executable \
  >"$result_dir/stdout.log" 2>"$result_dir/stderr.log"

staged="$active_output_dir/$(basename -- "$output_path")"
[[ -f "$staged" && ! -L "$staged" && -x "$staged" ]] \
  || die "validation did not return a regular executable"
cmp --silent -- "$artifact_path" "$staged" \
  || die "validated execution copy differs from the artifact"
cp --reflink=never -- "$staged" "$output_path"
chmod 0555 "$output_path"

{
  echo "artifact_format=$artifact_format"
  echo "artifact_path=$artifact_path"
  echo "artifact_bytes=$(stat --format='%s' "$artifact_path")"
  echo "artifact_sha256=$(sha256sum "$artifact_path" | awk '{print $1}')"
  echo "execution_path=$output_path"
  echo "execution_bytes=$(stat --format='%s' "$output_path")"
  echo "execution_sha256=$(sha256sum "$output_path" | awk '{print $1}')"
  echo "execution_file_type=$(file --brief -- "$output_path")"
  echo "execution_bytes_identical=yes"
  echo "validation_network=none"
  echo "validation_uid=65532"
} > "$result_dir/validation.env"

printf '%s\n' "$output_path"
