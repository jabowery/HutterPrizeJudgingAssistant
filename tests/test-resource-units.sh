#!/usr/bin/env bash
set -Eeuo pipefail

readonly project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$project_dir/lib/prize-limits.sh"
source "$project_dir/lib/resource-units.sh"

[[ "$HP_PEAK_RSS_LIMIT_BYTES" == 10737418240 ]]
[[ "$HP_EXECUTION_RAM_BYTES" == 17179869184 ]]
[[ "$(hp_format_gib "$HP_PEAK_RSS_LIMIT_BYTES")" == "10 GiB" ]]
[[ "$(hp_format_gib "$HP_EXECUTION_RAM_BYTES")" == "16 GiB" ]]
[[ "$(hp_format_gib 1207959552)" == "1.125 GiB" ]]
[[ "$(hp_format_gib 142606336)" == "0.1328125 GiB" ]]
[[ "$(hp_format_gib 1)" == "0.0000000009 GiB" ]]
[[ "$(hp_format_gb 100000000000)" == "100 GB" ]]
[[ "$(hp_format_gb 104857600)" == "0.1048576 GB" ]]
[[ "$(hp_format_gb 1)" == "0.000000001 GB" ]]
[[ "$(hp_format_hms 1)" == "00:00:01" ]]
[[ "$(hp_format_hms 30)" == "00:00:30" ]]
[[ "$(hp_format_hms 159191)" == "44:13:11" ]]
[[ "$(hp_format_hms 360000)" == "100:00:00" ]]

source "$project_dir/docker/runtime-report"
[[ "$(hp_format_gib_runtime 10737418240)" == "10 GiB" ]]
[[ "$(hp_format_gb_runtime 100000000000)" == "100 GB" ]]
[[ "$(hp_format_hms_runtime 360000)" == "100:00:00" ]]
runtime_status_start="$(date +%s)"
runtime_status_line="$(hp_emit_runtime_status \
  "$runtime_status_start" "$((runtime_status_start + 60))" \
  14000000000 100000000000 17179869184 /tmp/hutter-output-does-not-exist unavailable \
  2>&1)"
[[ "$runtime_status_line" == STATUS:*wall-elapsed=*wall-remaining=*cpu-used=unavailable* ]] \
  || { echo "runtime status did not distinguish wall and CPU time" >&2; exit 1; }
[[ "$runtime_status_line" == *disk=14\ GB/100\ GB* ]] \
  || { echo "runtime status did not report disk allocation" >&2; exit 1; }
[[ "$runtime_status_line" == *'output=hutter-output-does-not-exist=not-created' ]] \
  || { echo "runtime status did not report output state" >&2; exit 1; }
grep -q '^readonly status_interval_seconds=60$' \
  "$project_dir/docker/run-compressor"
grep -q '^readonly status_interval_seconds=60$' \
  "$project_dir/docker/run-archive"

qualify_help="$($project_dir/qualify-archive.sh --help)"
[[ "$qualify_help" == *"default: 10 GiB"* ]]
[[ "$qualify_help" == *"default: 100 GB"* ]]
[[ "$qualify_help" == *"process-tree (default)"* ]]
[[ "$qualify_help" == *"automatic ./Work"* ]]
[[ "$qualify_help" != *"10737418240 = 10 GiB"* ]]

assistance_help="$($project_dir/judging_assistance.sh --help)"
[[ "$assistance_help" == *"default: 10 GiB"* ]]
[[ "$assistance_help" == *"Default: 100 GB"* ]]
[[ "$assistance_help" == *"process-tree (default)"* ]]
[[ "$assistance_help" == *"automatic ./Work"* ]]

initial_capacity_line="$(grep -n '^check_work_capacity || die ' \
  "$project_dir/judging_assistance.sh" | cut -d: -f1)"
common_image_line="$(grep -n '^echo "Building the common judging image' \
  "$project_dir/judging_assistance.sh" | cut -d: -f1)"
post_dependency_capacity_line="$(grep -n '^check_work_capacity \\' \
  "$project_dir/judging_assistance.sh" | cut -d: -f1)"
compressor_build_line="$(grep -n 'if ! "$script_dir/build-compressor.sh"' \
  "$project_dir/judging_assistance.sh" | cut -d: -f1)"
(( initial_capacity_line < common_image_line ))
(( post_dependency_capacity_line < compressor_build_line ))

echo "resource unit format tests passed"
