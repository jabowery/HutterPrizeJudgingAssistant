#!/usr/bin/env bash
set -Eeuo pipefail

readonly project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$project_dir/lib/resource-units.sh"

[[ "$(hp_format_gib 10737418240)" == "10 GiB" ]]
[[ "$(hp_format_gib 1207959552)" == "1.125 GiB" ]]
[[ "$(hp_format_gb 100000000000)" == "100 GB" ]]
[[ "$(hp_format_gb 104857600)" == "0.104858 GB" ]]

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
