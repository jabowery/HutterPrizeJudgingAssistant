#!/usr/bin/env bash
set -Eeuo pipefail

readonly project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$project_dir/lib/resource-units.sh"

[[ "$(hp_format_gib 10737418240)" == "10 GiB" ]]
[[ "$(hp_format_gib 11811160064)" == "11 GiB" ]]
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
[[ "$qualify_help" == *"default: 1 GiB"* ]]
[[ "$qualify_help" == *"default: 100 GB"* ]]
[[ "$qualify_help" != *"10737418240 = 10 GiB"* ]]

assistance_help="$($project_dir/judging_assistance.sh --help)"
[[ "$assistance_help" == *"default: 10 GiB"* ]]
[[ "$assistance_help" == *"default: 1 GiB"* ]]
[[ "$assistance_help" == *"Default: 100 GB"* ]]

echo "resource unit format tests passed"
