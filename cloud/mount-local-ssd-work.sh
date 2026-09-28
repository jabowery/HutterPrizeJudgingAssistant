#!/usr/bin/env bash
set -Eeuo pipefail

# Trusted GCE startup metadata. Local SSD is explicitly for the disposable
# judging work tree; submissions and result evidence remain on persistent disk.
readonly device=/dev/disk/by-id/google-local-nvme-ssd-0
readonly work_root=/var/lib/hutter-prize-work

[[ -b "$device" ]] || { echo "missing requested local NVMe SSD: $device" >&2; exit 1; }
if ! mountpoint -q -- "$work_root"; then
  if ! blkid -- "$device" >/dev/null 2>&1; then
    mkfs.ext4 -F -- "$device"
  fi
  mkdir -p -- "$work_root"
  mount -- "$device" "$work_root"
fi
