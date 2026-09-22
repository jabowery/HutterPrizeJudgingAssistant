#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: sudo ./install-host-dependencies.sh

Install trusted host-side dependencies used by the judging system, including
Docker Engine when it is absent. This helper requires root and accepts no
options. Entrant-provided code is never executed here.
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

packages=(
  bash ca-certificates coreutils curl findutils git git-lfs grep mawk sed util-linux
)
if ! command -v docker >/dev/null 2>&1; then
  packages+=(apparmor docker.io)
fi

apt-get update
apt-get install --yes --no-install-recommends "${packages[@]}"

if command -v docker >/dev/null 2>&1 \
    && command -v systemctl >/dev/null 2>&1 \
    && [[ -d /run/systemd/system ]]; then
  systemctl enable --now docker
fi
