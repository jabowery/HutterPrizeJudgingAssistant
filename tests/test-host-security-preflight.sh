#!/usr/bin/env bash
set -Eeuo pipefail

readonly project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly test_dir="$(mktemp -d)"
cleanup() { rm -rf -- "$test_dir"; }
trap cleanup EXIT

mkdir "$test_dir/bin"
cat > "$test_dir/bin/docker" <<'EOF'
#!/bin/sh
set -eu
case "$1" in
  context)
    case "$2" in
      show) printf '%s\n' default ;;
      inspect) printf '%s\n' "${FAKE_DOCKER_ENDPOINT:-unix:///var/run/docker.sock}" ;;
      *) exit 90 ;;
    esac
    ;;
  info)
    case "$3" in
      '{{.OSType}}') printf '%s\n' "${FAKE_DOCKER_OS:-linux}" ;;
      '{{.KernelVersion}}') printf '%s\n' "${FAKE_DOCKER_KERNEL:?}" ;;
      '{{.ServerVersion}}') printf '%s\n' 29.1.3 ;;
      '{{range .SecurityOptions}}{{println .}}{{end}}')
        printf '%b' "${FAKE_DOCKER_SECURITY_OPTIONS:?}"
        ;;
      *) exit 91 ;;
    esac
    ;;
  run)
    printf '%b' "${FAKE_DOCKER_PROBE:?}"
    ;;
  *) exit 92 ;;
esac
EOF
chmod 0555 "$test_dir/bin/docker"

readonly orchestrator_kernel="$(uname -r)"
readonly apparmor_options='name=apparmor\nname=seccomp,profile=builtin\n'
readonly apparmor_probe='seccomp=2\nno_new_privs=1\nuid_map=0:0:4294967295\nlsm_context=docker-default (enforce)\n'

FAKE_DOCKER_KERNEL="$orchestrator_kernel" \
FAKE_DOCKER_SECURITY_OPTIONS="$apparmor_options" \
FAKE_DOCKER_PROBE="$apparmor_probe" \
PATH="$test_dir/bin:$PATH" \
  "$project_dir/host-security-preflight.sh" \
    --image test-image --report "$test_dir/pass.env" \
    > "$test_dir/pass.stdout" 2> "$test_dir/pass.stderr"
grep -q '^preflight_status=PASS$' "$test_dir/pass.env"
grep -q "^orchestrator_kernel=$orchestrator_kernel$" "$test_dir/pass.env"
grep -q "^docker_daemon_kernel=$orchestrator_kernel$" "$test_dir/pass.env"
grep -q '^enforcing_lsm=apparmor$' "$test_dir/pass.env"
grep -q '^identity_boundary=none$' "$test_dir/pass.env"
grep -q '^identity_boundary_advisory=present$' "$test_dir/pass.env"
grep -q '^kernel_patch_currency=unverified$' "$test_dir/pass.env"
grep -q 'rootful without UID remapping' "$test_dir/pass.stderr"

remapped_options='name=apparmor\nname=seccomp,profile=builtin\nname=userns\n'
remapped_probe='seccomp=2\nno_new_privs=1\nuid_map=0:231072:65536\nlsm_context=docker-default (enforce)\n'
FAKE_DOCKER_KERNEL="$orchestrator_kernel" \
FAKE_DOCKER_SECURITY_OPTIONS="$remapped_options" \
FAKE_DOCKER_PROBE="$remapped_probe" \
PATH="$test_dir/bin:$PATH" \
  "$project_dir/host-security-preflight.sh" \
    --image test-image --report "$test_dir/remapped.env" \
    > "$test_dir/remapped.stdout" 2> "$test_dir/remapped.stderr"
grep -q '^identity_boundary=uid-remapped$' "$test_dir/remapped.env"
grep -q '^identity_boundary_advisory=none$' "$test_dir/remapped.env"
! grep -q 'rootful without UID remapping' "$test_dir/remapped.stderr"

# An underlying VM or compatibility environment may expose a Docker kernel
# different from the orchestration shell's kernel. That relationship is
# recorded but is not itself a confinement failure.
virtualized_kernel='6.6.87.2-microsoft-standard-WSL2'
FAKE_DOCKER_KERNEL="$virtualized_kernel" \
FAKE_DOCKER_SECURITY_OPTIONS="$apparmor_options" \
FAKE_DOCKER_PROBE="$apparmor_probe" \
PATH="$test_dir/bin:$PATH" \
  "$project_dir/host-security-preflight.sh" \
    --image test-image --report "$test_dir/virtualized.env" \
    > "$test_dir/virtualized.stdout" 2> "$test_dir/virtualized.stderr"
grep -q '^preflight_status=PASS$' "$test_dir/virtualized.env"
grep -q "^orchestrator_kernel=$orchestrator_kernel$" \
  "$test_dir/virtualized.env"
grep -q "^docker_daemon_kernel=$virtualized_kernel$" \
  "$test_dir/virtualized.env"

expect_failure() {
  local name="$1" options="$2" probe="$3" expected="$4"
  set +e
  FAKE_DOCKER_KERNEL="$orchestrator_kernel" \
  FAKE_DOCKER_SECURITY_OPTIONS="$options" \
  FAKE_DOCKER_PROBE="$probe" \
  PATH="$test_dir/bin:$PATH" \
    "$project_dir/host-security-preflight.sh" \
      --image test-image --report "$test_dir/$name.env" \
      > "$test_dir/$name.stdout" 2> "$test_dir/$name.stderr"
  status=$?
  set -e
  (( status == 2 ))
  [[ ! -e "$test_dir/$name.env" ]]
  grep -q "$expected" "$test_dir/$name.stderr"
}

expect_failure no-seccomp 'name=apparmor\n' "$apparmor_probe" \
  'does not report an active seccomp profile'
expect_failure no-lsm 'name=seccomp,profile=builtin\n' "$apparmor_probe" \
  'neither AppArmor nor SELinux'
expect_failure unconfined "$apparmor_options" \
  'seccomp=2\nno_new_privs=1\nuid_map=0:0:4294967295\nlsm_context=unconfined\n' \
  'no verifiably enforcing AppArmor or SELinux profile'

set +e
FAKE_DOCKER_ENDPOINT='tcp://127.0.0.1:2375' \
FAKE_DOCKER_KERNEL="$orchestrator_kernel" \
FAKE_DOCKER_SECURITY_OPTIONS="$apparmor_options" \
FAKE_DOCKER_PROBE="$apparmor_probe" \
PATH="$test_dir/bin:$PATH" \
  "$project_dir/host-security-preflight.sh" \
    --image test-image --report "$test_dir/remote.env" \
    > "$test_dir/remote.stdout" 2> "$test_dir/remote.stderr"
remote_status=$?
set -e
(( remote_status == 2 ))
grep -q 'is not a local Unix socket' "$test_dir/remote.stderr"
[[ ! -e "$test_dir/remote.env" ]]

echo "host security preflight tests passed"
