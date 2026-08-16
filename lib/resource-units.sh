#!/usr/bin/env bash

# Human-facing resource units. Exact limits remain recorded as integer bytes in
# machine-readable evidence and command-line interfaces.

hp_format_gib() {
  # Ten fractional digits distinguish adjacent byte counts when expressed in
  # GiB; insignificant trailing zeroes are omitted.
  LC_ALL=C awk -v bytes="$1" '
    BEGIN {
      value = sprintf("%.10f", bytes / 1073741824)
      sub(/0+$/, "", value)
      sub(/[.]$/, "", value)
      printf "%s GiB", value
    }
  '
}

hp_format_gb() {
  # Decimal GB requires nine fractional digits for byte precision;
  # insignificant trailing zeroes are omitted.
  LC_ALL=C awk -v bytes="$1" '
    BEGIN {
      value = sprintf("%.9f", bytes / 1000000000)
      sub(/0+$/, "", value)
      sub(/[.]$/, "", value)
      printf "%s GB", value
    }
  '
}

hp_format_hms() {
  local total_seconds="$1"
  local hours minutes seconds
  hours="$((10#$total_seconds / 3600))"
  minutes="$(((10#$total_seconds % 3600) / 60))"
  seconds="$((10#$total_seconds % 60))"
  printf '%02d:%02d:%02d' "$hours" "$minutes" "$seconds"
}
