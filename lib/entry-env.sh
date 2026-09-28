#!/usr/bin/env bash

# Strict parser for the contestant-provided submission manifest.  This file is
# sourced by trusted host scripts; entry.env itself is never sourced.

if ! declare -F hp_qualification_os_image >/dev/null; then
  source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/qualification-os.sh"
fi

hp_manifest_die() {
  printf 'invalid entry.env: %s\n' "$*" >&2
  return 2
}

hp_manifest_basename() {
  if [[ ! "$2" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    hp_manifest_die "$1 must be a plain filename"
    return
  fi
  if [[ "$2" == . || "$2" == .. ]]; then
    hp_manifest_die "$1 must not be . or .."
    return
  fi
}

hp_manifest_archive_url() {
  local value="$1" remainder host path filename
  [[ "$value" == https://* && "$value" != *$'\n'* && "$value" != *$'\r'* \
      && "$value" != *' '* && "$value" != *$'\t'* ]] \
    || { hp_manifest_die "ARCHIVE URL must be a single-line HTTPS URL"; return; }
  remainder="${value#https://}"
  [[ "$remainder" == */* ]] \
    || { hp_manifest_die "ARCHIVE URL must contain a path ending in its filename"; return; }
  host="${remainder%%/*}"
  [[ "$host" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]+)?$ ]] \
    || { hp_manifest_die "ARCHIVE URL has an invalid HTTPS host"; return; }
  path="/${remainder#*/}"
  path="${path%%[?#]*}"
  filename="${path##*/}"
  hp_manifest_basename ARCHIVE "$filename" || return
  HP_ARCHIVE_URL="$value"
  HP_ARCHIVE="$filename"
}

hp_arguments_validate() {
  local arguments="$1" label="${2:-argument file}" final_byte
  [[ -f "$arguments" && ! -L "$arguments" ]] \
    || { hp_manifest_die "$label is missing or not a regular file"; return; }
  [[ -s "$arguments" ]] || return 0
  final_byte="$(tail --bytes=1 -- "$arguments" \
    | od --address-radix=n --format=u1 | tr -d '[:space:]')"
  [[ "$final_byte" == 10 ]] \
    || { hp_manifest_die "$label must end with a line feed"; return; }
  if ! LC_ALL=C tr -d '\nA-Za-z0-9_./:=+,%@-' < "$arguments" \
      | cmp --silent -- - /dev/null; then
    hp_manifest_die "$label contains a byte outside the permitted alphabet"
    return
  fi
  if grep --quiet '^$' "$arguments"; then
    hp_manifest_die "$label contains an empty argument"
    return
  fi
}

hp_manifest_load() {
  local manifest="$1" line key value
  [[ -f "$manifest" && ! -L "$manifest" ]] \
    || hp_manifest_die "missing regular manifest $manifest"

  HP_ENTRY_FORMAT=
  HP_EXECUTION_PLATFORM=
  HP_QUALIFICATION_OS=
  HP_SOURCE_PACKAGE=
  HP_COMPRESSOR=
  HP_COMPRESSOR_FORMAT=
  HP_COMPRESSOR_ARGUMENTS=
  HP_ARCHIVE=
  HP_ARCHIVE_URL=
  HP_ARCHIVE_SHA256=
  HP_ARCHIVE_FORMAT=
  HP_DECOMPRESSED_OUTPUT=
  HP_DECOMPRESSOR=
  HP_DECOMPRESSOR_FORMAT=
  HP_DECOMPRESSOR_ARGUMENTS=
  declare -A hp_seen=()

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" != *$'\r' ]] || line="${line%$'\r'}"
    case "$line" in
      ''|'#'*) continue ;;
      *=*) key="${line%%=*}"; value="${line#*=}" ;;
      *) hp_manifest_die "line is not KEY=VALUE: $line" || return ;;
    esac
    [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] \
      || { hp_manifest_die "invalid key: $key"; return; }
    [[ -z "${hp_seen[$key]+x}" ]] \
      || { hp_manifest_die "duplicate key: $key"; return; }
    hp_seen[$key]=1
    case "$key" in
      ENTRY_FORMAT) HP_ENTRY_FORMAT="$value" ;;
      EXECUTION_PLATFORM) HP_EXECUTION_PLATFORM="$value" ;;
      QUALIFICATION_OS) HP_QUALIFICATION_OS="$value" ;;
      SOURCE_PACKAGE) HP_SOURCE_PACKAGE="$value" ;;
      COMPRESSOR) HP_COMPRESSOR="$value" ;;
      COMPRESSOR_FORMAT) HP_COMPRESSOR_FORMAT="$value" ;;
      COMPRESSOR_ARGUMENTS) HP_COMPRESSOR_ARGUMENTS="$value" ;;
      ARCHIVE) HP_ARCHIVE="$value" ;;
      ARCHIVE_SHA256) HP_ARCHIVE_SHA256="$value" ;;
      ARCHIVE_FORMAT) HP_ARCHIVE_FORMAT="$value" ;;
      DECOMPRESSED_OUTPUT) HP_DECOMPRESSED_OUTPUT="$value" ;;
      DECOMPRESSOR) HP_DECOMPRESSOR="$value" ;;
      DECOMPRESSOR_FORMAT) HP_DECOMPRESSOR_FORMAT="$value" ;;
      DECOMPRESSOR_ARGUMENTS) HP_DECOMPRESSOR_ARGUMENTS="$value" ;;
      *) hp_manifest_die "unsupported key: $key" || return ;;
    esac
  done < "$manifest"

  case "$HP_ENTRY_FORMAT" in
    self-extracting|separate-decompressor) ;;
    *) hp_manifest_die "ENTRY_FORMAT must be self-extracting or separate-decompressor" || return ;;
  esac
  case "$HP_EXECUTION_PLATFORM" in
    linux-x86|linux-x86_64|windows-x86|windows-x86_64) ;;
    *) hp_manifest_die "unsupported EXECUTION_PLATFORM" || return ;;
  esac
  [[ -n "$HP_QUALIFICATION_OS" ]] \
    || { hp_manifest_die "missing QUALIFICATION_OS"; return; }
  [[ "$HP_QUALIFICATION_OS" =~ ^[a-z0-9][a-z0-9.-]*$ ]] \
    || { hp_manifest_die "QUALIFICATION_OS is not a plain catalog alias"; return; }
  case "$HP_EXECUTION_PLATFORM" in
    linux-x86|linux-x86_64)
      hp_qualification_os_image "$HP_QUALIFICATION_OS" >/dev/null \
        || { hp_manifest_die "unsupported QUALIFICATION_OS"; return; }
      ;;
  esac

  local required
  for required in SOURCE_PACKAGE COMPRESSOR COMPRESSOR_FORMAT \
      COMPRESSOR_ARGUMENTS ARCHIVE ARCHIVE_FORMAT DECOMPRESSED_OUTPUT; do
    value="HP_$required"
    [[ -n "${!value}" ]] || { hp_manifest_die "missing $required"; return; }
    case "$required" in
      COMPRESSOR_FORMAT|ARCHIVE_FORMAT|ARCHIVE) ;;
      *) hp_manifest_basename "$required" "${!value}" || return ;;
    esac
  done
  if [[ "$HP_ARCHIVE" == https://* ]]; then
    hp_manifest_archive_url "$HP_ARCHIVE" || return
  else
    hp_manifest_basename ARCHIVE "$HP_ARCHIVE" || return
  fi
  [[ -z "$HP_ARCHIVE_SHA256" || "$HP_ARCHIVE_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    || { hp_manifest_die "ARCHIVE_SHA256 must be a lowercase SHA-256 digest"; return; }
  case "$HP_COMPRESSOR_FORMAT" in executable|upx|upx-overlay) ;;
    *) hp_manifest_die "COMPRESSOR_FORMAT must be executable, upx, or upx-overlay" || return ;;
  esac

  if [[ "$HP_ENTRY_FORMAT" == separate-decompressor ]]; then
    for required in DECOMPRESSOR DECOMPRESSOR_FORMAT DECOMPRESSOR_ARGUMENTS; do
      value="HP_$required"
      [[ -n "${!value}" ]] || { hp_manifest_die "missing $required"; return; }
      if [[ "$required" == DECOMPRESSOR_FORMAT ]]; then
        case "${!value}" in executable|upx|upx-overlay) ;;
          *) hp_manifest_die "DECOMPRESSOR_FORMAT must be executable, upx, or upx-overlay" || return ;;
        esac
      else
        hp_manifest_basename "$required" "${!value}" || return
      fi
    done
    [[ "$HP_ARCHIVE_FORMAT" == data ]] \
      || { hp_manifest_die "separate-decompressor ARCHIVE_FORMAT must be data"; return; }
  elif [[ -n "$HP_DECOMPRESSOR$HP_DECOMPRESSOR_FORMAT$HP_DECOMPRESSOR_ARGUMENTS" ]]; then
    hp_manifest_die "DECOMPRESSOR fields are only valid for separate-decompressor entries" || return
  elif [[ "$HP_ARCHIVE_FORMAT" != executable && "$HP_ARCHIVE_FORMAT" != upx \
      && "$HP_ARCHIVE_FORMAT" != upx-overlay ]]; then
    hp_manifest_die "self-extracting ARCHIVE_FORMAT must be executable, upx, or upx-overlay" || return
  fi

  export HP_ENTRY_FORMAT HP_EXECUTION_PLATFORM HP_QUALIFICATION_OS HP_SOURCE_PACKAGE \
    HP_COMPRESSOR HP_COMPRESSOR_FORMAT HP_COMPRESSOR_ARGUMENTS \
    HP_ARCHIVE HP_ARCHIVE_URL HP_ARCHIVE_SHA256 HP_ARCHIVE_FORMAT HP_DECOMPRESSED_OUTPUT \
    HP_DECOMPRESSOR HP_DECOMPRESSOR_FORMAT HP_DECOMPRESSOR_ARGUMENTS
}

hp_manifest_require_linux() {
  case "$HP_EXECUTION_PLATFORM" in
    linux-x86|linux-x86_64) ;;
    *)
      hp_manifest_die "$HP_EXECUTION_PLATFORM requires a Windows judging worker; this Docker worker executes Linux binaries only"
      ;;
  esac
}
