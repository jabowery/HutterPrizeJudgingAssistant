#!/usr/bin/env bash
set -Eeuo pipefail

readonly project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly test_dir="$(mktemp -d)"
cleanup() { rm -rf -- "$test_dir"; }
trap cleanup EXIT

chmod 0777 "$test_dir"
docker build --tag hutter-prize-judging:local "$project_dir" >/dev/null

docker run --rm --network none --user 65532:65532 \
  --mount "type=bind,source=$test_dir,target=/output" \
  hutter-prize-judging:local /bin/sh -eu -c '
    cp /bin/dash /output/packed
    chmod u+w /output/packed
    /opt/upx/upx-5.1.1-amd64_linux/upx -9 /output/packed >/dev/null
  '

"$project_dir/validate-executable.sh" \
  --image hutter-prize-judging:local \
  --format upx \
  --results "$test_dir/pure-results" \
  --output "$test_dir/pure-execution" \
  "$test_dir/packed" >/dev/null
cmp --silent -- "$test_dir/packed" "$test_dir/pure-execution"

pure_evidence="$(find "$test_dir/pure-results" \
  -name validation.env -type f -print -quit)"
grep -q '^artifact_format=upx$' "$pure_evidence"
grep -q '^execution_bytes_identical=yes$' "$pure_evidence"

cp -- "$test_dir/packed" "$test_dir/overlay"
printf 'self-extracting payload\n' >> "$test_dir/overlay"
"$project_dir/validate-executable.sh" \
  --image hutter-prize-judging:local \
  --format upx-overlay \
  --results "$test_dir/overlay-results" \
  --output "$test_dir/overlay-execution" \
  "$test_dir/overlay" >/dev/null
cmp --silent -- "$test_dir/overlay" "$test_dir/overlay-execution"

overlay_evidence="$(find "$test_dir/overlay-results" \
  -name validation.env -type f -print -quit)"
grep -q '^artifact_format=upx-overlay$' "$overlay_evidence"
grep -q '^execution_bytes_identical=yes$' "$overlay_evidence"

# UPX transfers control within the declared process rather than invoking a
# second executable, so the packed bytes also satisfy the exec-once monitor.
docker run --rm --network none \
  --cap-drop ALL --cap-add SYS_PTRACE \
  --security-opt no-new-privileges=true \
  --mount "type=bind,source=$test_dir,target=/work/run,readonly" \
  hutter-prize-judging:local \
  /usr/local/bin/exec-once /work/run ./packed -c true

echo "executable validation tests passed"
