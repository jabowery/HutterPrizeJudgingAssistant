#!/usr/bin/env bash

hp_runtime_handoff_output_path() {
  local hp_rh_path="$1" hp_rh_label="$2" hp_rh_parent
  [[ -n "$hp_rh_path" ]] || return 0
  [[ ! -e "$hp_rh_path" && ! -L "$hp_rh_path" ]] || {
    printf 'error: %s already exists: %s\n' "$hp_rh_label" "$hp_rh_path" >&2
    return 2
  }
  hp_rh_parent="$(dirname -- "$hp_rh_path")"
  [[ -d "$hp_rh_parent" && ! -L "$hp_rh_parent" \
      && -w "$hp_rh_parent" ]] || {
    printf 'error: invalid %s directory: %s\n' "$hp_rh_label" "$hp_rh_parent" >&2
    return 2
  }
  realpath --canonicalize-missing -- "$hp_rh_path"
}

hp_runtime_handoff_gate_path() {
  local hp_rh_path="$1" hp_rh_parent
  [[ -n "$hp_rh_path" ]] || return 0
  hp_rh_parent="$(dirname -- "$hp_rh_path")"
  [[ -d "$hp_rh_parent" && ! -L "$hp_rh_parent" \
      && -w "$hp_rh_parent" ]] || {
    printf 'error: invalid start-gate directory: %s\n' "$hp_rh_parent" >&2
    return 2
  }
  realpath --canonicalize-missing -- "$hp_rh_path"
}

hp_runtime_handoff_wait_for_gate() {
  local hp_rh_gate="$1" hp_rh_ready="$2"
  [[ -n "$hp_rh_gate" && -n "$hp_rh_ready" ]] || return 0
  printf 'ready\n' > "$hp_rh_ready"
  chmod 0400 -- "$hp_rh_ready"
  while [[ ! -f "$hp_rh_gate" || -L "$hp_rh_gate" ]]; do
    sleep 0.1
  done
}
