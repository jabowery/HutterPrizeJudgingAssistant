#!/usr/bin/env bash
set -Eeuo pipefail

readonly project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly test_dir="$(mktemp -d)"
trap 'rm -rf -- "$test_dir"' EXIT

source "$project_dir/lib/qualification-os.sh"
source "$project_dir/lib/entry-env.sh"

[[ "$(hp_qualification_os_image ubuntu-20.04)" == \
  ubuntu:20.04@sha256:8feb4d8ca5354def3d8fce243717141ce31e2c428701f6682bd2fafe15388214 ]]
[[ "$(hp_qualification_os_image ubuntu-22.04)" == \
  ubuntu:22.04@sha256:58b87898e82351c6cf9cf5b9f3c20257bb9e2dcf33af051e12ce532d7f94e3fe ]]
[[ "$(hp_qualification_os_image ubuntu-24.04)" == \
  ubuntu:24.04@sha256:b3cc40b72b93588182b5410f723c7aaf142363311c2aa993d8a453ddcbb3ae15 ]]
[[ "$(hp_qualification_os_image_tag ubuntu-24.04)" == \
  hutter-prize-judging:ubuntu-24.04 ]]
! hp_qualification_os_image 'registry.example/entrant:latest' >/dev/null 2>&1

write_manifest() {
  local qualification_line="$1"
  cat > "$test_dir/entry.env" <<EOF
ENTRY_FORMAT=self-extracting
EXECUTION_PLATFORM=linux-x86_64
$qualification_line
SOURCE_PACKAGE=source.tar.gz
COMPRESSOR=comp9
COMPRESSOR_FORMAT=executable
COMPRESSOR_ARGUMENTS=comp9.args
ARCHIVE=archive9
ARCHIVE_FORMAT=executable
DECOMPRESSED_OUTPUT=data9
EOF
}

write_manifest 'QUALIFICATION_OS=ubuntu-24.04'
hp_manifest_load "$test_dir/entry.env"
[[ "$HP_QUALIFICATION_OS" == ubuntu-24.04 ]]

write_manifest 'QUALIFICATION_OS=registry.example/entrant:latest'
! hp_manifest_load "$test_dir/entry.env" >/dev/null 2>&1

write_manifest '# QUALIFICATION_OS is required'
! hp_manifest_load "$test_dir/entry.env" >/dev/null 2>&1

grep -q '^ARG QUALIFICATION_OS_IMAGE=' "$project_dir/Dockerfile"
grep -q '^FROM \${QUALIFICATION_OS_IMAGE} AS launcher-build$' "$project_dir/Dockerfile"
grep -q '^FROM \${QUALIFICATION_OS_IMAGE}$' "$project_dir/Dockerfile"
