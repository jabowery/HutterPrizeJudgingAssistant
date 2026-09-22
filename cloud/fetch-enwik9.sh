#!/usr/bin/env bash
set -Eeuo pipefail

readonly enwik9_url=https://www.mattmahoney.net/dc/enwik9.zip
readonly enwik9_zip_bytes=322592222
readonly enwik9_bytes=1000000000
readonly enwik9_md5=e206c3450ac99950df65bf70ef61a12d
readonly enwik9_sha256=159b85351e5f76e60cbe32e04c677847a9ecba3adc79addab6f4c6c7aa3744bc

usage() {
  cat <<'EOF'
Usage: ./cloud/fetch-enwik9.sh OUTPUT_FILE

Download the canonical enwik9 ZIP from Matt Mahoney's test-data site, extract
it into the output filesystem, and atomically install it only after its size,
MD5, and SHA-256 have been verified. This is a trusted cloud-setup helper and
must run before entrant code is executed.
EOF
}

die() {
  echo "error: enwik9 fetch: $*" >&2
  exit 2
}

if (( $# == 1 )) && [[ "$1" == -h || "$1" == --help ]]; then
  usage
  exit 0
fi
(( $# == 1 )) || { usage >&2; exit 2; }
[[ "$1" != -* ]] || { echo "error: unknown option: $1" >&2; usage >&2; exit 2; }

output_file="$1"
[[ "$output_file" == /* && "$output_file" != / ]] \
  || die "OUTPUT_FILE must be an absolute path other than /"
output_parent="$(dirname -- "$output_file")"
[[ -d "$output_parent" && ! -L "$output_parent" ]] \
  || die "output parent is not a regular directory: $output_parent"
[[ ! -L "$output_file" ]] || die "output must not be a symbolic link"
[[ ! -e "$output_file" || -f "$output_file" ]] \
  || die "output must be absent or a regular file"

command -v curl >/dev/null 2>&1 || die "curl is unavailable"
command -v unzip >/dev/null 2>&1 || die "unzip is unavailable"
command -v flock >/dev/null 2>&1 || die "flock is unavailable"

verify_enwik9() {
  local candidate="$1"
  [[ -f "$candidate" && ! -L "$candidate" ]] || return 1
  [[ "$(stat --format='%s' "$candidate")" == "$enwik9_bytes" ]] || return 1
  [[ "$(md5sum -- "$candidate" | awk '{print $1}')" == "$enwik9_md5" ]] \
    || return 1
  [[ "$(sha256sum -- "$candidate" | awk '{print $1}')" == "$enwik9_sha256" ]]
}

lock_file="$output_parent/.enwik9-fetch.lock"
exec 9>"$lock_file"
flock 9

if verify_enwik9 "$output_file"; then
  printf '%s  %s\n' "$enwik9_sha256" "$output_file"
  exit 0
fi

stage_dir="$(mktemp -d -- "$output_parent/.enwik9-fetch.XXXXXX")"
cleanup() {
  rm -rf -- "$stage_dir"
}
trap cleanup EXIT

zip_file="$stage_dir/enwik9.zip"
extract_dir="$stage_dir/extracted"
mkdir -- "$extract_dir"

curl --fail --location --retry 5 --retry-all-errors \
  --connect-timeout 30 --output "$zip_file" "$enwik9_url"
[[ "$(stat --format='%s' "$zip_file")" == "$enwik9_zip_bytes" ]] \
  || die "downloaded ZIP has an unexpected size"
mapfile -t zip_members < <(unzip -Z1 "$zip_file")
[[ "${zip_members[*]}" == enwik9 ]] \
  || die "ZIP member list was not exactly enwik9"
unzip -qq "$zip_file" -d "$extract_dir"

mapfile -t extracted_paths < <(
  find -P "$extract_dir" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort
)
[[ "${extracted_paths[*]}" == enwik9 ]] \
  || die "ZIP did not contain exactly one top-level enwik9 file"
verify_enwik9 "$extract_dir/enwik9" \
  || die "downloaded enwik9 failed canonical digest verification"

chmod 0444 "$extract_dir/enwik9"
mv -f -- "$extract_dir/enwik9" "$output_file"
printf '%s  %s\n' "$enwik9_sha256" "$output_file"
