#!/usr/bin/env bash
set -Eeuo pipefail

# This deliberately narrow root helper prepares the coordination lock and
# performs the host-kernel cache operation. It never executes entrant code or
# the residency verifier.

prepare_lock=false
target=""

usage() {
  cat <<'EOF'
Usage:
  sudo ./cold-cache-host-helper.sh --prepare-lock
  sudo ./cold-cache-host-helper.sh --target FILE

Prepare the judging system's host cache-eviction lock, or evict clean cache
pages and report evidence for one exact regular file. This narrowly privileged
helper is normally invoked by the orchestrator, not run directly.
EOF
}

die() {
  echo "error: cold-cache helper: $*" >&2
  exit 2
}

usage_error() {
  echo "error: cold-cache helper: $*" >&2
  echo >&2
  usage >&2
  exit 2
}

while (( $# > 0 )); do
  case "$1" in
    --prepare-lock)
      prepare_lock=true
      shift
      ;;
    --target)
      (( $# >= 2 )) || usage_error "$1 requires a value"
      target="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) usage_error "unknown option: $1" ;;
  esac
done

if [[ "$prepare_lock" != true && -z "$target" ]]; then
  usage_error "--prepare-lock or --target FILE is required"
fi
(( EUID == 0 )) || die "must run as root"
if [[ "$prepare_lock" == true ]]; then
  [[ -z "$target" ]] || usage_error "--prepare-lock does not accept --target"
  lock_path=/run/lock/hutter-prize-cold-cache.lock
  mkdir -p -- /run/lock
  if [[ ! -e "$lock_path" && ! -L "$lock_path" ]]; then
    /usr/bin/install --mode=0666 --owner=0 --group=0 /dev/null "$lock_path"
  fi
  [[ -f "$lock_path" && ! -L "$lock_path" \
      && "$(stat --format='%u:%g' -- "$lock_path")" == 0:0 ]] \
    || die "cold-cache lock is not a root-owned regular file"
  chmod 0666 -- "$lock_path"
  exit 0
fi
[[ -n "$target" && -f "$target" && ! -L "$target" ]] \
  || die "target is not a regular nonsymlink file: $target"
[[ -w /proc/sys/vm/drop_caches ]] \
  || die "/proc/sys/vm/drop_caches is not writable in this Linux environment"

target="$(realpath -- "$target")"
target_identity_before="$(stat --format='%d:%i:%s' -- "$target")"

echo "eviction_started_utc=$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)"
echo "target_path=$target"
echo "target_device_inode_size=$target_identity_before"
echo "drop_caches_value=3"
/usr/bin/sync
printf '3\n' > /proc/sys/vm/drop_caches

target_identity_after="$(stat --format='%d:%i:%s' -- "$target")"
[[ "$target_identity_after" == "$target_identity_before" ]] \
  || die "target identity changed during eviction"
echo "eviction_completed_utc=$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)"
