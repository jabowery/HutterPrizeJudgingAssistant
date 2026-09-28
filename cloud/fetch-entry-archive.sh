#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  echo "Usage: fetch-entry-archive.sh URL OUTPUT [EXPECTED_SHA256]" >&2
  exit 2
}

(( $# == 2 || $# == 3 )) || usage
readonly archive_url="$1"
readonly output="$2"
readonly expected_sha256="${3:-}"

[[ "$archive_url" == https://* ]] || { echo "error: archive URL must use HTTPS" >&2; exit 2; }
[[ -z "$expected_sha256" || "$expected_sha256" =~ ^[0-9a-f]{64}$ ]] \
  || { echo "error: expected SHA-256 must be lowercase hexadecimal" >&2; exit 2; }

readonly output_dir="$(dirname -- "$output")"
mkdir -p -- "$output_dir"
readonly temporary="$(mktemp "$output_dir/.archive-download.XXXXXX")"
trap 'rm -f -- "$temporary"' EXIT

curl --fail --location --retry 3 --retry-delay 1 \
  --proto '=https' --proto-redir '=https' \
  --output "$temporary" -- "$archive_url"
[[ -f "$temporary" && ! -L "$temporary" ]] \
  || { echo "error: archive download is not a regular file" >&2; exit 1; }

actual_sha256="$(sha256sum -- "$temporary" | awk '{print $1}')"
if [[ -n "$expected_sha256" && "$actual_sha256" != "$expected_sha256" ]]; then
  echo "error: downloaded archive SHA-256 does not match ARCHIVE_SHA256" >&2
  exit 1
fi
mv -f -- "$temporary" "$output"
printf '%s\n' "$actual_sha256"
