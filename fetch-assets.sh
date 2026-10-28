#!/usr/bin/env bash
set -Eeuo pipefail
readonly script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/lib/assets.sh"
usage() {
  cat <<'EOF'
Usage: ./fetch-assets.sh [--cache-dir DIR] [--include-example]

Populate the checksum-verified asset cache and materialize the pinned Linux
Geekbench and UPX archives. Existing files and Git LFS objects seed the cache;
otherwise tools come directly from their publishers, never from Git LFS.
Build/run scripts invoke this automatically before building the common image.

Options:
  --cache-dir DIR     Override the persistent cache (HP_ASSET_CACHE_DIR)
  --include-example   Also cache/materialize the public procedural fixture;
                      its first cache miss still requires Git LFS bandwidth
  -h, --help          Show this help

Defaults: $XDG_CACHE_HOME/hutter-prize/assets (or ~/.cache/hutter-prize/assets)
for an ordinary user; /var/cache/hutter-prize/assets when running as root.
No credentials, contestant submissions or judging results enter this cache.
EOF
}
usage_error() { echo "error: $*" >&2; usage >&2; exit 2; }
include_example=false
while (( $# )); do
  case "$1" in
    --cache-dir) (( $# >= 2 )) || usage_error "$1 requires a value"; export HP_ASSET_CACHE_DIR="$2"; shift 2 ;;
    --include-example) include_example=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage_error "unknown argument: $1" ;;
  esac
done
hp_tool_assets_ensure "$script_dir"
if [[ "$include_example" == true ]]; then
  hp_example_assets_ensure "$script_dir" "$script_dir/examples/well-formed-entry"
fi
