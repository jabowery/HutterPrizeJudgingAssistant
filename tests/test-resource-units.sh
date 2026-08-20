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

qualify_help="$($project_dir/qualify-archive.sh --help)"
[[ "$qualify_help" == *"default: 10 GiB"* ]]
[[ "$qualify_help" == *"default: 100 GB"* ]]
[[ "$qualify_help" != *"10737418240 = 10 GiB"* ]]

assistance_help="$($project_dir/judging_assistance.sh --help)"
[[ "$assistance_help" == *"default: 10 GiB"* ]]
[[ "$assistance_help" == *"Default: 100 GB"* ]]

echo "resource unit format tests passed"
