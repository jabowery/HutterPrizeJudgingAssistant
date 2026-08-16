#!/usr/bin/env bash
set -Eeuo pipefail

readonly project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly entry_dir="$project_dir/Entries/Example"
readonly test_dir="$(mktemp -d)"
trap 'rm -rf -- "$test_dir"' EXIT

mapfile -t entry_files < <(
  find -P "$entry_dir" -mindepth 1 -maxdepth 1 -type f \
    -printf '%f\n' | LC_ALL=C sort
)
[[ "${entry_files[*]}" == "archive9 entry.env example-source.tar.gz" ]]

grep -qx 'SOURCE_PACKAGE=example-source.tar.gz' "$entry_dir/entry.env"
grep -qx 'COMPRESSOR=comp9' "$entry_dir/entry.env"
grep -qx 'COMPRESSOR_FORMAT=executable' "$entry_dir/entry.env"
grep -qx 'COMPRESSOR_ARGUMENTS=comp9.args' "$entry_dir/entry.env"
grep -qx 'ARCHIVE=archive9' "$entry_dir/entry.env"
grep -qx 'ARCHIVE_FORMAT=executable' "$entry_dir/entry.env"
grep -qx 'DECOMPRESSED_OUTPUT=data9' "$entry_dir/entry.env"

tar --extract --gzip --file "$entry_dir/example-source.tar.gz" \
  --directory "$test_dir"
readonly source_dir="$test_dir/example-source"
[[ -f "$source_dir/example-codec.c" ]]
[[ -x "$source_dir/install.sh" ]]
[[ -x "$source_dir/build.sh" ]]
[[ -f "$source_dir/comp9.args" ]]

grep -q -- '-march=x86-64 -mtune=generic' "$source_dir/build.sh"
! grep -q -- '-march=native\|-mtune=native' "$source_dir/build.sh"
grep -q 'ZSTD_c_compressionLevel, 1' "$source_dir/example-codec.c"
grep -q 'not derived from a' "$source_dir/README.md"
grep -q 'Hutter Prize submission' "$source_dir/README.md"
! grep -Rqi --exclude=LICENSE -- 'Vladimir\|fx2-cmix\|cmix-transformer' \
  "$source_dir"

file "$entry_dir/archive9" | grep -q \
  'ELF 64-bit LSB executable, x86-64.*statically linked'

echo "Example entry fixture tests passed"
