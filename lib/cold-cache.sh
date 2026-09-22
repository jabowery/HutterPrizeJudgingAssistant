#!/usr/bin/env bash

hp_cold_cache_extract_mincore_helper() {
  local image="$1"
  local output="$2"
  local container=""

  mkdir -p -- "$(dirname -- "$output")" || return 1
  container="$(docker create "$image" /bin/true)" || return 1
  if ! docker cp \
      "$container:/usr/local/bin/mincore-residency" "$output"; then
    docker rm --force "$container" >/dev/null 2>&1 || true
    return 1
  fi
  docker rm "$container" >/dev/null || return 1
  chmod 0555 -- "$output" || return 1
  [[ -f "$output" && ! -L "$output" && -x "$output" ]]
}

hp_cold_cache_acquire_lock() {
  local orchestrator_dir="$1"
  local lock_path=/run/lock/hutter-prize-cold-cache.lock
  command -v flock >/dev/null || {
    echo "error: --cold-cache requires flock from util-linux" >&2
    return 2
  }
  if [[ "${HP_COLD_CACHE_LOCK_HELD:-}" == 1 \
      && "${HP_COLD_CACHE_LOCK_FD:-}" =~ ^[0-9]+$ \
      && -e "/proc/$$/fd/$HP_COLD_CACHE_LOCK_FD" \
      && "$(readlink -- "/proc/$$/fd/$HP_COLD_CACHE_LOCK_FD")" == "$lock_path" ]]; then
    return 0
  fi
  unset HP_COLD_CACHE_LOCK_HELD HP_COLD_CACHE_LOCK_FD

  if (( EUID == 0 )); then
    "$orchestrator_dir/cold-cache-host-helper.sh" --prepare-lock || return
  else
    command -v sudo >/dev/null || {
      echo "error: --cold-cache requires sudo for host cache control" >&2
      return 2
    }
    sudo --validate || return
    sudo --non-interactive -- "$orchestrator_dir/cold-cache-host-helper.sh" \
      --prepare-lock || return
  fi
  [[ -f "$lock_path" && ! -L "$lock_path" \
      && "$(stat --format='%u:%g' -- "$lock_path")" == 0:0 ]] || {
    echo "error: invalid host-wide cold-cache lock" >&2
    return 2
  }
  exec {HP_COLD_CACHE_LOCK_FD}<>"$lock_path"
  if ! flock --exclusive --nonblock "$HP_COLD_CACHE_LOCK_FD"; then
    echo "error: another cache-controlled judging run is active" >&2
    echo "Inspect its lock holder with: sudo lslocks --output PID,COMMAND,MODE,PATH | grep hutter-prize-cold-cache" >&2
    echo "Do not delete $lock_path while it may be locked." >&2
    return 2
  fi
  export HP_COLD_CACHE_LOCK_HELD=1
  export HP_COLD_CACHE_LOCK_FD
}

hp_cold_cache_refresh_privilege() {
  if (( EUID != 0 )); then
    sudo --validate || return
  fi
}

hp_cold_cache_validate_work_root() {
  local work_root="$1"
  local reference_path="${2:-}"
  local kernel_release filesystem_type storage_path storage_role i
  local -a storage_paths=("$work_root")
  local -a storage_roles=("work storage")

  kernel_release="$(uname -r)"
  if [[ "${kernel_release,,}" != *microsoft* ]]; then
    return 0
  fi

  if [[ -n "$reference_path" ]]; then
    storage_paths+=("$reference_path")
    storage_roles+=("enwik9 input")
  fi
  for ((i = 0; i < ${#storage_paths[@]}; ++i)); do
    storage_path="${storage_paths[i]}"
    storage_role="${storage_roles[i]}"
    case "$storage_path" in
      /mnt/[a-zA-Z]|/mnt/[a-zA-Z]/*)
        echo "error: --cold-cache under WSL requires $storage_role on a Linux filesystem, not $storage_path" >&2
        return 2
        ;;
    esac
    if command -v findmnt >/dev/null; then
      filesystem_type="$(findmnt --noheadings --output FSTYPE --target "$storage_path" \
        | awk 'NR == 1 {print $1}')"
      case "$filesystem_type" in
        9p|drvfs)
          echo "error: --cold-cache under WSL rejects $filesystem_type $storage_role" >&2
          return 2
          ;;
      esac
    fi
  done
  if [[ "$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)" != 0 ]]; then
    echo "error: --cold-cache under WSL requires swap=0" >&2
    return 2
  fi
  echo "WARNING: WSL does not expose a reliable check for autoMemoryReclaim=disabled or for cache below the guest kernel; verify those formal-run conditions separately." >&2
}

hp_cold_cache_run() {
  local orchestrator_dir="$1"
  local mincore_helper="$2"
  local target="$3"
  local evidence_file="$4"
  local target_bytes="$5"
  local target_sha256="$6"
  local target_role="$7"
  local temporary_evidence
  local lock_path=/run/lock/hutter-prize-cold-cache.lock

  [[ "${HP_COLD_CACHE_LOCK_HELD:-}" == 1 \
      && "${HP_COLD_CACHE_LOCK_FD:-}" =~ ^[0-9]+$ \
      && -e "/proc/$$/fd/$HP_COLD_CACHE_LOCK_FD" \
      && "$(readlink -- "/proc/$$/fd/$HP_COLD_CACHE_LOCK_FD")" == "$lock_path" ]] || {
    echo "error: cold-cache execution requires the host-wide lock" >&2
    return 2
  }
  [[ -f "$mincore_helper" && ! -L "$mincore_helper" \
      && -x "$mincore_helper" ]] || {
    echo "error: invalid mincore helper: $mincore_helper" >&2
    return 2
  }
  [[ -f "$target" && ! -L "$target" ]] || {
    echo "error: invalid cold-cache target: $target" >&2
    return 2
  }

  temporary_evidence="$(mktemp -- "$(dirname -- "$evidence_file")/.cold-cache.XXXXXX")" \
    || return 1
  {
    echo "cold_cache=enabled"
    echo "target_role=$target_role"
    echo "target_bytes=$target_bytes"
    echo "target_sha256=$target_sha256"
    echo "mincore_helper_sha256=$(sha256sum -- "$mincore_helper" | awk '{print $1}')"
    if (( EUID == 0 )); then
      "$orchestrator_dir/cold-cache-host-helper.sh" --target "$target"
    else
      sudo --non-interactive -- "$orchestrator_dir/cold-cache-host-helper.sh" \
        --target "$target"
    fi
    "$mincore_helper" --require-zero "$target"
    echo "eviction_verified_utc=$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)"
    echo "cold_cache_status=PASS"
  } > "$temporary_evidence" || {
    local status=$?
    mv -- "$temporary_evidence" "$evidence_file"
    return "$status"
  }
  mv -- "$temporary_evidence" "$evidence_file"
}
