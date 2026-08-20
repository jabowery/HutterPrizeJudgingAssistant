#!/usr/bin/env bash
set -Eeuo pipefail

image=""
report_path=""

usage() {
  cat <<'EOF'
Usage: ./host-security-preflight.sh --image IMAGE --report FILE

Verify the Docker Linux security boundary before any entrant-provided code is
executed. The check requires a Linux Docker daemon, seccomp filtering,
no-new-privileges, and an enforcing AppArmor or SELinux container profile.
The underlying environment may be native or virtualized; this script neither
requires nor rejects virtualization. Rootless Docker or UID remapping is
reported as an additional boundary; its absence produces a warning.
EOF
}

die() {
  echo "error: host security preflight: $*" >&2
  exit 2
}

while (( $# > 0 )); do
  case "$1" in
    --image)
      (( $# >= 2 )) || die "$1 requires a value"
      image="$2"
      shift 2
      ;;
    --report)
      (( $# >= 2 )) || die "$1 requires a value"
      report_path="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ -n "$image" ]] || die "--image is required"
[[ -n "$report_path" ]] || die "--report is required"
[[ -d "$(dirname -- "$report_path")" ]] \
  || die "report directory does not exist"
[[ ! -e "$report_path" && ! -L "$report_path" ]] \
  || die "report path already exists"
command -v docker >/dev/null || die "Docker is not installed or is not in PATH"

orchestrator_kernel="$(uname -r)"
if [[ -n "${DOCKER_HOST:-}" ]]; then
  daemon_endpoint="$DOCKER_HOST"
else
  docker_context="$(docker context show)" \
    || die "could not determine the active Docker context"
  daemon_endpoint="$(docker context inspect "$docker_context" \
    --format '{{.Endpoints.docker.Host}}')" \
    || die "could not determine the Docker daemon endpoint"
fi
case "$daemon_endpoint" in
  unix:///*) ;;
  *) die "Docker endpoint '$daemon_endpoint' is not a local Unix socket" ;;
esac

daemon_os="$(docker info --format '{{.OSType}}')" \
  || die "could not determine Docker daemon OS"
daemon_kernel="$(docker info --format '{{.KernelVersion}}')" \
  || die "could not determine Docker daemon kernel"
daemon_version="$(docker info --format '{{.ServerVersion}}')" \
  || die "could not determine Docker daemon version"
security_options="$(docker info \
  --format '{{range .SecurityOptions}}{{println .}}{{end}}')" \
  || die "could not determine Docker security options"

[[ "$daemon_os" == linux ]] \
  || die "Docker daemon OS is $daemon_os, not Linux"

seccomp_option=no
apparmor_option=no
selinux_option=no
rootless_option=no
userns_option=no
while IFS= read -r option; do
  case "$option" in
    name=seccomp|name=seccomp,*) seccomp_option=yes ;;
    name=apparmor) apparmor_option=yes ;;
    name=selinux) selinux_option=yes ;;
    name=rootless) rootless_option=yes ;;
    name=userns) userns_option=yes ;;
  esac
done <<< "$security_options"

[[ "$seccomp_option" == yes ]] \
  || die "Docker does not report an active seccomp profile"
[[ "$apparmor_option" == yes || "$selinux_option" == yes ]] \
  || die "Docker reports neither AppArmor nor SELinux container confinement"

selinux_enforcing=no
if [[ "$selinux_option" == yes ]]; then
  if [[ -r /sys/fs/selinux/enforce \
      && "$(< /sys/fs/selinux/enforce)" == 1 ]]; then
    selinux_enforcing=yes
  elif command -v getenforce >/dev/null \
      && [[ "$(getenforce 2>/dev/null || true)" == Enforcing ]]; then
    selinux_enforcing=yes
  fi
fi

probe_output="$(docker run --rm \
  --network none \
  --read-only \
  --cap-drop ALL \
  --security-opt no-new-privileges=true \
  "$image" /bin/sh -eu -c '
    awk '\''/^Seccomp:/ {print "seccomp=" $2}
         /^NoNewPrivs:/ {print "no_new_privs=" $2}'\'' /proc/self/status
    awk '\''NR == 1 {print "uid_map=" $1 ":" $2 ":" $3}'\'' /proc/self/uid_map
    if [ -r /proc/self/attr/current ]; then
      printf "lsm_context="
      tr -d "\n" < /proc/self/attr/current
      printf "\n"
    else
      printf "lsm_context=unavailable\n"
    fi
  ')" || die "could not execute the trusted Docker confinement probe"

runtime_seccomp=""
runtime_no_new_privs=""
runtime_uid_map=""
runtime_lsm_context=""
while IFS='=' read -r key value; do
  case "$key" in
    seccomp) runtime_seccomp="$value" ;;
    no_new_privs) runtime_no_new_privs="$value" ;;
    uid_map) runtime_uid_map="$value" ;;
    lsm_context) runtime_lsm_context="$value" ;;
  esac
done <<< "$probe_output"

[[ "$runtime_seccomp" == 2 ]] \
  || die "test container is not running in seccomp filter mode"
[[ "$runtime_no_new_privs" == 1 ]] \
  || die "test container does not have no-new-privileges set"

enforcing_lsm=""
if [[ "$apparmor_option" == yes \
    && "$runtime_lsm_context" == *"(enforce)"* \
    && "$runtime_lsm_context" != unconfined* ]]; then
  enforcing_lsm=apparmor
elif [[ "$selinux_option" == yes && "$selinux_enforcing" == yes \
    && -n "$runtime_lsm_context" \
    && "$runtime_lsm_context" != unconfined* \
    && "$runtime_lsm_context" != unavailable ]]; then
  enforcing_lsm=selinux
fi
[[ -n "$enforcing_lsm" ]] \
  || die "test container has no verifiably enforcing AppArmor or SELinux profile (context: $runtime_lsm_context)"

IFS=: read -r container_uid host_uid uid_count <<< "$runtime_uid_map"
[[ "$container_uid" =~ ^[0-9]+$ && "$host_uid" =~ ^[0-9]+$ \
    && "$uid_count" =~ ^[0-9]+$ ]] \
  || die "test container returned an invalid UID map: $runtime_uid_map"

identity_boundary=none
identity_boundary_advisory=present
if (( host_uid != 0 )); then
  identity_boundary=uid-remapped
  identity_boundary_advisory=none
elif [[ "$rootless_option" == yes || "$userns_option" == yes ]]; then
  die "Docker reports rootless/userns isolation but the test container maps UID 0 to host UID 0"
fi

{
  echo "preflight_status=PASS"
  echo "orchestrator_kernel=$orchestrator_kernel"
  echo "docker_daemon_endpoint=$daemon_endpoint"
  echo "docker_daemon_os=$daemon_os"
  echo "docker_daemon_kernel=$daemon_kernel"
  echo "docker_server_version=$daemon_version"
  echo "seccomp_option=$seccomp_option"
  echo "runtime_seccomp_mode=$runtime_seccomp"
  echo "runtime_no_new_privs=$runtime_no_new_privs"
  echo "enforcing_lsm=$enforcing_lsm"
  echo "runtime_lsm_context=$runtime_lsm_context"
  echo "rootless_option=$rootless_option"
  echo "userns_option=$userns_option"
  echo "runtime_uid_map=$runtime_uid_map"
  echo "identity_boundary=$identity_boundary"
  echo "identity_boundary_advisory=$identity_boundary_advisory"
  echo "kernel_patch_currency=unverified"
} > "$report_path"

echo "Host security preflight PASS: Linux Docker kernel, seccomp, no-new-privileges, $enforcing_lsm" >&2
if [[ "$identity_boundary" == none ]]; then
  echo "WARNING: Docker is rootful without UID remapping; container UID 0 maps to host UID 0. Entrant executables still run as UID 65532, but rootless Docker or user-namespace remapping would add an identity boundary." >&2
else
  echo "Host security preflight: container UID 0 is remapped to host UID $host_uid." >&2
fi
echo "WARNING: This preflight cannot prove that the Docker daemon's Linux kernel and Docker Engine contain no unpatched container-escape vulnerability; keep both current with vendor security updates." >&2
