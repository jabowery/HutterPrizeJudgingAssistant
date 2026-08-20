#!/usr/bin/env bash
set -Eeuo pipefail

readonly project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly test_dir="$(mktemp -d)"
trap 'rm -rf -- "$test_dir"' EXIT

source "$project_dir/lib/entry-env.sh"

# A missing manifest is reported once, without a shell redirection error or a
# second diagnostic about fields that could not have been read.
set +e
missing_diagnostics="$(hp_manifest_load "$test_dir/absent/entry.env" 2>&1 >/dev/null)"
missing_status=$?
set -e
(( missing_status == 2 ))
[[ "$missing_diagnostics" == "invalid entry.env: missing regular manifest $test_dir/absent/entry.env" ]]

cat > "$test_dir/entry.env" <<'EOF'
ENTRY_FORMAT=self-extracting
EXECUTION_PLATFORM=linux-x86_64
SOURCE_PACKAGE=comp9.tar.gz
COMPRESSOR=comp9
COMPRESSOR_FORMAT=executable
COMPRESSOR_ARGUMENTS=comp9.args
ARCHIVE=archive9
ARCHIVE_FORMAT=executable
DECOMPRESSED_OUTPUT=data9
EOF
hp_manifest_load "$test_dir/entry.env"
[[ "$HP_ENTRY_FORMAT" == self-extracting ]]
[[ "$HP_ARCHIVE" == archive9 ]]

echo "entry manifest tests passed"
