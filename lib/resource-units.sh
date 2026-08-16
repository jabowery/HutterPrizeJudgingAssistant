#!/usr/bin/env bash

# Human-facing resource units. Exact limits remain recorded as integer bytes in
# machine-readable evidence and command-line interfaces.

hp_format_gib() {
  # Ten fractional digits distinguish adjacent byte counts when expressed in
  # GiB: one byte is approximately 0.000000000931 GiB.
  LC_ALL=C awk -v bytes="$1" 'BEGIN { printf "%.10f GiB", bytes / 1073741824 }'
}

hp_format_gb() {
  # Decimal GB requires exactly nine fractional digits for byte precision.
  LC_ALL=C awk -v bytes="$1" 'BEGIN { printf "%.9f GB", bytes / 1000000000 }'
}

hp_format_hms() {
  local total_seconds="$1"
  local hours minutes seconds
  hours="$((10#$total_seconds / 3600))"
  minutes="$(((10#$total_seconds % 3600) / 60))"
  seconds="$((10#$total_seconds % 60))"
  printf '%02d:%02d:%02d' "$hours" "$minutes" "$seconds"
}
