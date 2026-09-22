#!/usr/bin/env bash

# Ensure trusted host tools exist before Docker or Git LFS is needed. Package
# installation remains isolated in install-host-dependencies.sh so this library
# never performs privileged package-manager operations itself.

hp_host_dependencies_ensure() {
  local orchestrator_dir="$1" command_name
  local -a missing=()

  for command_name in \
      docker git curl flock realpath sha256sum stat df find sort awk sed timeout; do
    command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
  done
  if command -v git >/dev/null 2>&1 \
      && ! git lfs version >/dev/null 2>&1; then
    missing+=(git-lfs)
  fi
  (( ${#missing[@]} > 0 )) || return 0

  printf 'Installing missing trusted host dependencies: %s\n' \
    "${missing[*]}" >&2
  if (( EUID == 0 )); then
    "$orchestrator_dir/install-host-dependencies.sh"
  else
    command -v sudo >/dev/null 2>&1 || {
      echo "error: installing host dependencies requires sudo" >&2
      return 2
    }
    sudo -- "$orchestrator_dir/install-host-dependencies.sh"
  fi

  for command_name in \
      docker git curl flock realpath sha256sum stat df find sort awk sed timeout; do
    command -v "$command_name" >/dev/null 2>&1 || {
      printf 'error: host dependency installation did not provide %s\n' \
        "$command_name" >&2
      return 2
    }
  done
  git lfs version >/dev/null 2>&1 || {
    echo "error: host dependency installation did not provide Git LFS" >&2
    return 2
  }
}
