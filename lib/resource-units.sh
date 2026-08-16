#!/usr/bin/env bash

# Human-facing resource units. Exact limits remain recorded as integer bytes in
# machine-readable evidence and command-line interfaces.

hp_format_gib() {
  LC_ALL=C awk -v bytes="$1" 'BEGIN { printf "%.6g GiB", bytes / 1073741824 }'
}

hp_format_gb() {
  LC_ALL=C awk -v bytes="$1" 'BEGIN { printf "%.6g GB", bytes / 1000000000 }'
}
