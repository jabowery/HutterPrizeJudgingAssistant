#!/usr/bin/env bash

# Trusted asset catalog. No entrant-supplied URL or checksum is accepted here.
hp_asset_catalog() {
  case "$1" in
    Geekbench-5.5.1-Linux.tar.gz)
      printf '%s\t%s\t%s\n' \
        32037e55c3dc8f360fe16b7fbb188d31387ea75980e48d8cf028330e3239c404 \
        93199992 https://cdn.geekbench.com/Geekbench-5.5.1-Linux.tar.gz ;;
    UPX-5.1.1-amd64_linux.tar.xz)
      printf '%s\t%s\t%s\n' \
        1ff660454227861e00772f743f66b900072116b9dc24f6ee28b97cce88a7828a \
        655036 https://github.com/upx/upx/releases/download/v5.1.1/upx-5.1.1-amd64_linux.tar.xz ;;
    examples/well-formed-entry/archive9)
      printf '%s\t%s\t%s\n' \
        bf4a4ac6595d1f2506c7240fe546d95efe82308859e98dc6134ff2e2d02c6640 \
        359695801 lfs ;;
    examples/well-formed-entry/example-source.tar.gz)
      printf '%s\t%s\t%s\n' \
        33fe154628803dd4a25fb6b4737cee311a69b2d65bbb3e89f88c3f6f2d31429c \
        4204 lfs ;;
    *) printf 'error: asset is not in the trusted catalog: %s\n' "$1" >&2; return 2 ;;
  esac
}

hp_asset_cache_dir() {
  if [[ -n "${HP_ASSET_CACHE_DIR:-}" ]]; then
    printf '%s\n' "$HP_ASSET_CACHE_DIR"
  elif (( EUID == 0 )); then
    printf '/var/cache/hutter-prize/assets\n'
  else
    printf '%s/hutter-prize/assets\n' "${XDG_CACHE_HOME:-$HOME/.cache}"
  fi
}

hp_asset_valid() {
  [[ -f "$1" && ! -L "$1" \
      && "$(stat --format='%s' -- "$1")" == "$3" ]] || return 1
  [[ "$(sha256sum -- "$1" | awk '{print $1}')" == "$2" ]]
}

hp_asset_lfs_object() {
  local hp_ac_repo="$1" hp_ac_sha="$2" hp_ac_objects
  # Respect an existing lfs.storage cache as well as the default .git path.
  hp_ac_objects="$(git -C "$hp_ac_repo" lfs env 2>/dev/null \
    | awk '/^LocalMediaDir=/ {print substr($0,15); exit}')" || hp_ac_objects=
  if [[ -z "$hp_ac_objects" ]]; then
    hp_ac_objects="$(git -C "$hp_ac_repo" rev-parse --git-path lfs/objects 2>/dev/null)" || return
  fi
  [[ "$hp_ac_objects" == /* ]] || hp_ac_objects="$hp_ac_repo/$hp_ac_objects"
  printf '%s/%s/%s/%s\n' "$hp_ac_objects" "${hp_ac_sha:0:2}" "${hp_ac_sha:2:2}" "$hp_ac_sha"
}

# Subshell owns the lock and temporary files, including on interrupted fetches.
hp_asset_ensure() (
  local hp_ac_repo="$1" hp_ac_name="$2" hp_ac_record hp_ac_sha hp_ac_size hp_ac_url
  local hp_ac_cache hp_ac_object hp_ac_target hp_ac_local hp_ac_source= hp_ac_first=
  local hp_ac_tmp= hp_ac_stage= hp_ac_lock_fd hp_ac_mode=0644
  hp_ac_record="$(hp_asset_catalog "$hp_ac_name")" || return
  IFS=$'\t' read -r hp_ac_sha hp_ac_size hp_ac_url <<< "$hp_ac_record"
  hp_ac_target="$hp_ac_repo/$hp_ac_name"
  hp_ac_cache="$(hp_asset_cache_dir)"
  [[ "$hp_ac_cache" == /* && "$hp_ac_cache" != / \
      && "$hp_ac_cache" != *$'\n'* && ! -L "$hp_ac_cache" ]] || {
    echo 'error: asset cache must be an absolute, non-symlink directory' >&2; return 2;
  }
  [[ ! -L "$hp_ac_target" ]] || {
    printf 'error: asset path is a symlink: %s\n' "$hp_ac_target" >&2; return 2;
  }
  if [[ -e "$hp_ac_target" ]]; then
    if hp_asset_valid "$hp_ac_target" "$hp_ac_sha" "$hp_ac_size"; then
      hp_ac_source="$hp_ac_target"
    else
      if [[ -f "$hp_ac_target" && "$(stat -c %s -- "$hp_ac_target")" -le 1024 ]]; then
        IFS= read -r hp_ac_first < "$hp_ac_target" || true
      fi
      [[ "$hp_ac_first" == 'version https://git-lfs.github.com/spec/v1' ]] || {
        printf 'error: %s failed its pinned SHA-256/size check; existing file was preserved\n' "$hp_ac_name" >&2
        return 2
      }
    fi
  fi
  (umask 077; mkdir -p -- "$hp_ac_cache") || return
  hp_ac_object="$hp_ac_cache/$hp_ac_sha"
  [[ ! -L "$hp_ac_object" && ! -L "$hp_ac_object.lock" ]] || {
    echo 'error: refusing symlink in asset cache' >&2; return 2;
  }
  exec {hp_ac_lock_fd}>"$hp_ac_object.lock" || return
  flock --exclusive "$hp_ac_lock_fd" || return
  trap '[[ -z "$hp_ac_tmp" ]] || rm -f -- "$hp_ac_tmp"; [[ -z "$hp_ac_stage" ]] || rm -f -- "$hp_ac_stage"' EXIT
  if hp_asset_valid "$hp_ac_object" "$hp_ac_sha" "$hp_ac_size"; then
    echo "Using verified cached asset: $hp_ac_name" >&2
  else
    hp_ac_tmp="$(mktemp -- "$hp_ac_cache/.asset.XXXXXX")" || return
    if [[ -z "$hp_ac_source" ]]; then
      hp_ac_local="$(hp_asset_lfs_object "$hp_ac_repo" "$hp_ac_sha")" || hp_ac_local=
      if hp_asset_valid "$hp_ac_local" "$hp_ac_sha" "$hp_ac_size"; then
        hp_ac_source="$hp_ac_local"
      fi
    fi
    if [[ -n "$hp_ac_source" ]]; then
      echo "Caching existing verified asset: $hp_ac_name" >&2
      cp --reflink=auto -- "$hp_ac_source" "$hp_ac_tmp" || return
    elif [[ "$hp_ac_url" == https://* ]]; then
      echo "Downloading pinned asset from its publisher (not Git LFS): $hp_ac_name" >&2
      curl --fail --show-error --location --proto '=https' --proto-redir '=https' \
        --connect-timeout 30 --max-time 600 --retry 3 --max-filesize "$hp_ac_size" \
        --output "$hp_ac_tmp" "$hp_ac_url" || return
    else
      # Only the explicitly selected public fixture has an LFS-only origin.
      # Never fall back to metered LFS for Geekbench or UPX.
      echo "Fetching selected public example on cache miss (uses Git LFS bandwidth once): $hp_ac_name" >&2
      git -C "$hp_ac_repo" lfs fetch --include="$hp_ac_name" --exclude='' origin HEAD || return
      hp_ac_local="$(hp_asset_lfs_object "$hp_ac_repo" "$hp_ac_sha")" || return
      hp_asset_valid "$hp_ac_local" "$hp_ac_sha" "$hp_ac_size" || {
        echo 'error: fetched example object failed its pinned SHA-256/size check' >&2; return 2;
      }
      cp --reflink=auto -- "$hp_ac_local" "$hp_ac_tmp" || return
    fi
    hp_asset_valid "$hp_ac_tmp" "$hp_ac_sha" "$hp_ac_size" || {
      printf 'error: downloaded/copied %s failed its pinned SHA-256/size check\n' "$hp_ac_name" >&2; return 2;
    }
    chmod 0444 -- "$hp_ac_tmp" || return
    mv -fT -- "$hp_ac_tmp" "$hp_ac_object" || return
    hp_ac_tmp=
  fi
  if [[ "$hp_ac_source" != "$hp_ac_target" ]]; then
    hp_ac_stage="$(mktemp -- "$(dirname -- "$hp_ac_target")/.asset.XXXXXX")" || return
    cp --reflink=auto -- "$hp_ac_object" "$hp_ac_stage" || return
    hp_asset_valid "$hp_ac_stage" "$hp_ac_sha" "$hp_ac_size" || return 2
    [[ "$hp_ac_name" != examples/well-formed-entry/archive9 ]] || hp_ac_mode=0555
    chmod "$hp_ac_mode" -- "$hp_ac_stage" || return
    mv -fT -- "$hp_ac_stage" "$hp_ac_target" || return
    hp_ac_stage=
  fi
)

hp_tool_assets_ensure() {
  hp_asset_ensure "$1" Geekbench-5.5.1-Linux.tar.gz || return
  hp_asset_ensure "$1" UPX-5.1.1-amd64_linux.tar.xz
}

hp_example_assets_ensure() {
  local hp_ac_repo="$1" hp_ac_entry="$2" hp_ac_source_only="${3:-false}"
  [[ "$hp_ac_entry" == "$hp_ac_repo/examples/well-formed-entry" ]] || return 0
  hp_asset_ensure "$hp_ac_repo" examples/well-formed-entry/example-source.tar.gz || return
  [[ "$hp_ac_source_only" == true ]] \
    || hp_asset_ensure "$hp_ac_repo" examples/well-formed-entry/archive9
}
