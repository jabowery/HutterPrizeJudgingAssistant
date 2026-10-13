#!/usr/bin/env bash
set -Eeuo pipefail
readonly project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
mkdir -p "$test_root/report" "$test_root/run"
printf 'checksum fixture\n' > "$test_root/reference"
cp "$test_root/reference" "$test_root/run/output"
printf 'output\n' > "$test_root/report/output_name"
# Exercise the real trusted verifier with fixture paths, without Docker,
# privileged mounts, or touching any formal run/cache on this host.
verify() {
  bash < <(sed \
    -e "s|^readonly report_dir=/work/report$|readonly report_dir=$test_root/report|" \
    -e "s|^readonly run_dir=/work/run$|readonly run_dir=$test_root/run|" \
    -e "s|^readonly reference=/reference/enwik9$|readonly reference=$test_root/reference|" \
    "$project_dir/docker/verify-output")
}
md5="$(md5sum "$test_root/reference" | awk '{print $1}')"
sha256="$(sha256sum "$test_root/reference" | awk '{print $1}')"
result="$(verify)"
[[ "$result" == *"reference_md5=$md5"* && "$result" == *"output_md5=$md5"* ]]
[[ "$result" == *"reference_sha256=$sha256"* && "$result" == *"output_sha256=$sha256"* ]]
[[ "$result" == *'verification=pass'*'reason=identical'* ]]
printf 'CHECKSUM fixture\n' > "$test_root/run/output"
if result="$(verify)"; then
  echo 'FAIL: changed content passed verification' >&2
  exit 1
fi
[[ "$result" == *'verification=fail'*'reason=content_mismatch'* ]]
changed_md5="$(md5sum "$test_root/run/output" | awk '{print $1}')"
[[ "$result" == *"output_md5=$changed_md5"* && "$changed_md5" != "$md5" ]]
echo 'report checksum tests passed'
