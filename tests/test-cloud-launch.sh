#!/usr/bin/env bash
set -Eeuo pipefail

readonly project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

fake_bin="$test_root/bin"
mkdir -p -- "$fake_bin"
cat > "$fake_bin/gcloud" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$GCLOUD_TEST_LOG"
case "$*" in
  *"compute instances list"*)
    exit 0
    ;;
  *"compute machine-types list"*)
    printf '%s\n' \
      'https://www.googleapis.com/compute/v1/projects/example/zones/us-central1-a' \
      'https://www.googleapis.com/compute/v1/projects/example/zones/us-central1-b'
    ;;
  *"compute machine-types describe"*)
    printf '%s\n' 16384
    ;;
  *"compute instances create"*"--zone=us-central1-a"*)
    exit 1
    ;;
  *"compute instances create"*"--zone=us-central1-b"*)
    exit 0
    ;;
  *"compute instances describe"*)
    exit 0
    ;;
  *"compute scp"*)
    if [[ ! -e "$GCLOUD_SCP_STATE" ]]; then
      : > "$GCLOUD_SCP_STATE"
      exit 255
    fi
    exit 0
    ;;
  *"compute ssh"*)
    if [[ ! -e "$GCLOUD_SSH_STATE" ]]; then
      : > "$GCLOUD_SSH_STATE"
      exit 255
    fi
    exit 0
    ;;
  *)
    echo "unexpected fake gcloud invocation: $*" >&2
    exit 90
    ;;
esac
EOF
chmod 0500 -- "$fake_bin/gcloud"

export GCLOUD_TEST_LOG="$test_root/gcloud.log"
export GCLOUD_SCP_STATE="$test_root/scp-state"
export GCLOUD_SSH_STATE="$test_root/ssh-state"
selected_zone="$(
  PATH="$fake_bin:$PATH" "$project_dir/provision-gcp-instance.sh" \
    --project example-project \
    --name test-hutter-system \
    --machine-type t2d-standard-4 \
    --boot-disk-size 240GB \
    --tags wg-node \
    2>"$test_root/provision.stderr"
)" || fail "provisioner rejected the fake capacity fallback"
[[ "$selected_zone" == us-central1-b ]] \
  || fail "provisioner did not return the successful zone"
grep -q 'instances create test-hutter-system.*--zone=us-central1-a' \
  "$GCLOUD_TEST_LOG" || fail "first candidate zone was not attempted"
grep -q 'instances create test-hutter-system.*--zone=us-central1-b' \
  "$GCLOUD_TEST_LOG" || fail "second candidate zone was not attempted"
grep -q -- '--boot-disk-size=240GB' "$GCLOUD_TEST_LOG" \
  || fail "disk-size override was not forwarded"
grep -q -- '--tags=wg-node' "$GCLOUD_TEST_LOG" \
  || fail "network tags were not forwarded"
grep -q -- '--no-service-account' "$GCLOUD_TEST_LOG" \
  || fail "instance was not stripped of its service account"
grep -q -- '--no-scopes' "$GCLOUD_TEST_LOG" \
  || fail "instance OAuth scopes were not disabled"
grep -q -- '--metadata=block-project-ssh-keys=TRUE,serial-port-enable=FALSE' \
  "$GCLOUD_TEST_LOG" || fail "project SSH keys or the serial port were not disabled"
grep -q -- '--shielded-secure-boot' "$GCLOUD_TEST_LOG" \
  || fail "Shielded VM Secure Boot was not requested"
grep -q -- '--shielded-vtpm' "$GCLOUD_TEST_LOG" \
  || fail "Shielded VM vTPM was not requested"
grep -q -- '--shielded-integrity-monitoring' "$GCLOUD_TEST_LOG" \
  || fail "Shielded VM integrity monitoring was not requested"

cat > "$fake_bin/sleep" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SLEEP_TEST_LOG"
EOF
chmod 0500 -- "$fake_bin/sleep"
export SLEEP_TEST_LOG="$test_root/sleep.log"
source "$project_dir/lib/gcloud-transfer.sh"
PATH="$fake_bin:$PATH" hp_gcloud_scp_with_retry \
  test-hutter-system example-project us-central1-b \
  "$test_root/source" /tmp/destination \
  >"$test_root/scp.stdout" 2>"$test_root/scp.stderr" \
  || fail "cloud upload was not retried successfully"
[[ "$(grep -c 'compute scp' "$GCLOUD_TEST_LOG")" == 2 ]] \
  || fail "cloud upload did not stop after the successful retry"
grep -q 'attempt 1/5 failed' "$test_root/scp.stderr" \
  || fail "cloud upload retry was not reported"
grep -q '^5$' "$SLEEP_TEST_LOG" \
  || fail "cloud upload retry did not back off"

: > "$SLEEP_TEST_LOG"
PATH="$fake_bin:$PATH" hp_gcloud_ssh_with_retry \
  test-hutter-system example-project us-central1-b \
  'sha256sum /tmp/upload' 'Verifying test upload' \
  >"$test_root/ssh.stdout" 2>"$test_root/ssh.stderr" \
  || fail "idempotent cloud SSH operation was not retried successfully"
[[ "$(grep -c 'compute ssh' "$GCLOUD_TEST_LOG")" == 2 ]] \
  || fail "cloud SSH operation did not stop after the successful retry"
grep -q 'SSH attempt 1/5 failed' "$test_root/ssh.stderr" \
  || fail "cloud SSH retry was not reported"
grep -q '^5$' "$SLEEP_TEST_LOG" \
  || fail "cloud SSH retry did not back off"

make_entry() {
  local entry_dir="$1"
  mkdir -p -- "$entry_dir"
  printf 'source\n' > "$entry_dir/source.tar.gz"
  cat > "$entry_dir/entry.env" <<'EOF'
ENTRY_FORMAT=self-extracting
EXECUTION_PLATFORM=linux-x86_64
QUALIFICATION_OS=ubuntu-24.04
SOURCE_PACKAGE=source.tar.gz
COMPRESSOR=comp9
COMPRESSOR_FORMAT=executable
COMPRESSOR_ARGUMENTS=comp9.args
ARCHIVE=archive9
ARCHIVE_FORMAT=executable
DECOMPRESSED_OUTPUT=enwik9_uncompressed
EOF
}

reference="$test_root/enwik9"
truncate --size=1000000000 "$reference"
source_entry="$test_root/SourceOnly"
make_entry "$source_entry"
source_plan="$test_root/source-plan"
"$project_dir/launch-cloud-judging.sh" --dry-run \
  --machine-type n4d-highmem-2 --tmux-history-lines 100000 \
  --reuse-instance \
  "$source_entry" "$reference" > "$source_plan"
grep -q '^machine_type=n4d-highmem-2$' "$source_plan" \
  || fail "launcher did not retain its machine override"
grep -q '^archive_present=no$' "$source_plan" \
  || fail "launcher did not detect an absent archive"
grep -q '^execution_mode=source_only$' "$source_plan" \
  || fail "launcher did not select source-only execution"
grep -q '^reuse_instance=true$' "$source_plan" \
  || fail "launcher did not retain its resume selection"
grep -q '^judging_command=.*--source-only' "$source_plan" \
  || fail "source-only command did not include --source-only"
grep -q '^judging_command=.*\.\./HutterPrizeSubmissions/SourceOnly' \
  "$source_plan" \
  || fail "cloud run did not keep the entry outside the cloned repository"

full_entry="$test_root/FullSubmission"
make_entry "$full_entry"
printf 'archive\n' > "$full_entry/archive9"
full_plan="$test_root/full-plan"
"$project_dir/launch-cloud-judging.sh" --dry-run \
  "$full_entry" "$reference" > "$full_plan"
grep -q '^archive_present=yes$' "$full_plan" \
  || fail "launcher did not detect a submitted archive"
grep -q '^execution_mode=full_submission$' "$full_plan" \
  || fail "launcher did not select the full workflow"
if grep -q '^judging_command=.*--source-only' "$full_plan"; then
  fail "full-submission command unexpectedly included --source-only"
fi
grep -q '^judging_command=.*\.\./HutterPrizeSubmissions/FullSubmission' \
  "$full_plan" \
  || fail "full cloud run did not use the external submission directory"

cat > "$fake_bin/tmux" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TMUX_TEST_LOG"
case "${1:-}" in
  has-session) exit 1 ;;
  show-options) printf '%s\n' "$TMUX_EXPECTED_HISTORY" ;;
  source-file|new-session) exit 0 ;;
  *) exit 90 ;;
esac
EOF
chmod 0500 -- "$fake_bin/tmux"
tmux_home="$test_root/home"
tmux_work="$test_root/work"
mkdir -p -- "$tmux_home" "$tmux_work"
export TMUX_TEST_LOG="$test_root/tmux.log"
export TMUX_EXPECTED_HISTORY=100000
PATH="$fake_bin:$PATH" HOME="$tmux_home" \
  "$project_dir/scripts/run-in-tmux.sh" \
    --session cloud-test --history-limit 100000 --workdir "$tmux_work" \
    -- printf '%s\n' hello > "$test_root/tmux.stdout"
grep -q '^set-option -g history-limit 100000$' \
  "$tmux_home/.tmux.hutter-prize.conf" \
  || fail "tmux history was not configured"
grep -q '^new-session -d -s cloud-test ' "$TMUX_TEST_LOG" \
  || fail "detached tmux session was not requested"
generated_runner="$tmux_home/.local/state/hutter-prize-cloud/cloud-test/run.sh"
bash -n "$generated_runner" || fail "generated tmux command script is invalid"
grep -q 'tee ' "$generated_runner" || fail "tmux command does not retain a log"
grep -Fq "printf '%s\\n' Judging" "$generated_runner" \
  || fail "generated tmux start notice does not contain a line feed"

echo "cloud launch tests passed"
