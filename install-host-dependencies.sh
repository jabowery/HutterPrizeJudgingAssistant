#!/usr/bin/env bash
set -Eeuo pipefail

if (( $# != 0 )); then
  echo "Usage: sudo ./install-host-dependencies.sh" >&2
  exit 2
fi
if (( EUID != 0 )); then
  echo "error: install-host-dependencies.sh must be run as root" >&2
  exit 2
fi
command -v apt-get >/dev/null \
  || { echo "error: automatic host dependency installation requires apt-get" >&2; exit 2; }

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install --yes --no-install-recommends git-lfs
