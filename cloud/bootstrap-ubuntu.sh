#!/usr/bin/env bash
set -Eeuo pipefail

work_root=/var/lib/hutter-prize-work

usage() {
  cat <<'EOF'
Usage: sudo ./cloud/bootstrap-ubuntu.sh [--work-root ABSOLUTE_PATH]

Patch an Ubuntu cloud host and install the trusted host software required by
the judging system. This internal helper must run through sudo so it can assign
the work directory to the invoking SSH user. It never processes entrant files.
EOF
}

die() {
  echo "error: cloud bootstrap: $*" >&2
  exit 2
}

while (( $# > 0 )); do
  case "$1" in
    --work-root)
      (( $# >= 2 )) || die "$1 requires a value"
      work_root="$2"
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

(( EUID == 0 )) || die "must run as root"
[[ "${SUDO_UID:-}" =~ ^[0-9]+$ && "${SUDO_GID:-}" =~ ^[0-9]+$ ]] \
  || die "must be invoked through sudo by the SSH user"
[[ "$work_root" == /* && "$work_root" != / ]] \
  || die "work-root must be an absolute path other than /"
[[ ! -L "$work_root" ]] || die "work-root must not be a symbolic link"
command -v apt-get >/dev/null 2>&1 \
  || die "automatic cloud bootstrap requires an apt-based Ubuntu host"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
apt-get update
apt-get dist-upgrade --yes
apt-get install --yes --no-install-recommends \
  apparmor bash ca-certificates coreutils curl diffutils docker.io file \
  findutils git git-lfs grep gzip mawk openssh-client psmisc sed tar tmux \
  util-linux

if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
  systemctl enable --now docker
fi
git lfs install --system --skip-smudge

mkdir -p -- "$work_root"
[[ -d "$work_root" && ! -L "$work_root" ]] \
  || die "could not create a regular work-root directory"
chown "$SUDO_UID:$SUDO_GID" -- "$work_root"
chmod 0755 -- "$work_root"
