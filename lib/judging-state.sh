#!/usr/bin/env bash

# Trusted orchestration metadata; readers parse this as data, never source it.
hp_judging_state_write() {
  [[ -n "${run_results:-}" && -d "$run_results" ]] || return 0
  local hp_js_stage="$1" hp_js_lifecycle="${2:-running}" hp_js_exit="${3:-pending}"
  local hp_js_tmp="$run_results/.judging-state.env.$$"
  {
    printf 'schema_version=1\nlifecycle=%s\ncurrent_stage=%s\nexit_code=%s\n' \
      "$hp_js_lifecycle" "$hp_js_stage" "$hp_js_exit"
    printf 'updated_utc=%s\norchestrator_pid=%s\nhost_boot_id=%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$$" \
      "$(< /proc/sys/kernel/random/boot_id)"
    printf 'orchestrator_start_ticks=%s\n' "$(awk '{print $22}' /proc/$$/stat)"
    printf 'source_only=%s\narchive_name=%s\ncompressor_name=%s\n' \
      "$source_only" "$HP_ARCHIVE" "$HP_COMPRESSOR"
    printf 'compression_only=%s\n' "${compression_only:-false}"
  } > "$hp_js_tmp"
  chmod 0444 -- "$hp_js_tmp"
  mv -f -- "$hp_js_tmp" "$run_results/judging-state.env"
  hp_judging_current_stage="$hp_js_stage"
}
