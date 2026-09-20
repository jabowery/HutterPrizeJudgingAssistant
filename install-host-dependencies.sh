#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: sudo ./install-host-dependencies.sh

Install the trusted host-side Git LFS dependency used by the judging system.
This helper requires root and accepts no options.
EOF
}

if (( $# == 1 )) && [[ "$1" == -h || "$1" == --help ]]; then
  usage
  exit 0
fi
if (( $# != 0 )); then
  echo "error: this helper accepts no arguments" >&2
  echo >&2
  usage >&2
  exit 2
fi
if (( EUID != 0 )); then
  echo "error: install-host-dependencies.sh must be run as root" >&2
  echo >&2
  usage >&2
  exit 2
fi
command -v apt-get >/dev/null \
  || { echo "error: automatic host dependency installation requires apt-get" >&2; exit 2; }

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install --yes --no-install-recommends git-lfs
