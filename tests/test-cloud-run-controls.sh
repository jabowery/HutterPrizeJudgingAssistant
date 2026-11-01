#!/usr/bin/env bash
set -Eeuo pipefail
readonly project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
source "$project_dir/lib/cloud-run-controls.sh"
run="$test_root/run with spaces"
hp_cloud_run_controls_create "$project_dir" "$run"
[[ "$(stat -c %a "$run")" == 700 ]] || fail 'run directory is not private'
mkdir "$test_root/bin" "$test_root/bundle"
printf 'private result\n' > "$test_root/bundle/result.txt"
tar -czf "$test_root/bundle.tar.gz" -C "$test_root/bundle" result.txt
export TEST_GCLOUD_LOG="$test_root/gcloud.log" TEST_BUNDLE="$test_root/bundle.tar.gz"
cat > "$test_root/bin/gcloud" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$TEST_GCLOUD_LOG"
case "$*" in
  *'--command=if sudo -n true'*'tar -C '*)
    if [[ "${TEST_CORRUPT:-false}" == true ]]; then echo 'bad download'; else cat "$TEST_BUNDLE"; fi ;;
  *OPERATOR_ATTENTION:*) echo 'OPERATOR_ATTENTION: phase=compression reason=test' ;;
  *) echo 'fake cloud response' ;;
esac
EOF
cat > "$test_root/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 78
EOF
cat > "$test_root/bin/notify-send" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$test_root/bin/"*
export PATH="$test_root/bin:$PATH"
cat > "$run/launch.env" <<'EOF'
instance_name=hpja-fixture
project=example-project
zone=us-east1-b
tmux_socket=hutter-prize-fixture
tmux_session=fixture
launch_phase=started
workflow_attempted=true
remote_results=/home/operator/Results/cloud-run-original
remote_log=/home/operator/Results/cloud-run-original/workflow.log
EOF
printf 'secret=$(touch %s)\n' "$test_root/should-not-exist" >> "$run/launch.env"
chmod 0400 "$run/launch.env"
for helper in "$run/"*.sh; do
  bash -n "$helper"
  [[ "$(stat -c %a "$helper")" == 500 ]] || fail 'helper permissions changed'
  "$helper" --help | grep -q '^Usage:' || fail 'helper has no usage feedback'
done
# Use helpers outside the repository and from an unrelated working directory.
cd /tmp
"$run/connect.sh" > /dev/null
grep -qx 'hpja-fixture' "$TEST_GCLOUD_LOG"
grep -qx -- '--project=example-project' "$TEST_GCLOUD_LOG"
grep -qx -- '--zone=us-east1-b' "$TEST_GCLOUD_LOG"
"$run/attach.sh" > /dev/null
grep -q 'tmux -L hutter-prize-fixture attach-session -t fixture' "$TEST_GCLOUD_LOG"
"$run/status.sh" > /dev/null
grep -q '/home/operator/Results/cloud-run-original' "$TEST_GCLOUD_LOG" \
  || fail 'status did not use the original run scope'
"$run/report.sh" > /dev/null
grep -q -- '--report-only' "$TEST_GCLOUD_LOG"
set +e
"$run/watch.sh" 2 > /dev/null
watch_exit=$?
"$run/notify.sh" 2 > /dev/null 2> "$test_root/notice"
notice_exit=$?
set -e
[[ "$watch_exit" == 78 && "$notice_exit" == 3 ]] || fail 'watch/notification helpers failed'
"$run/logs.sh" > /dev/null
grep -q 'tail -n 40 -F -- /home/operator/Results/cloud-run-original/workflow.log' "$TEST_GCLOUD_LOG"
"$run/fetch-results.sh" > /dev/null
cmp "$TEST_BUNDLE" "$run/downloads/results.tar.gz" || fail 'results download corrupt'
[[ ! -e "$run/downloads/result.txt" ]] || fail 'download was automatically extracted'
if TEST_CORRUPT=true "$run/fetch-results.sh" > /dev/null 2> "$test_root/bad-download"; then
  fail 'corrupt results download accepted'
fi
cmp "$TEST_BUNDLE" "$run/downloads/results.tar.gz" || fail 'failed download replaced good evidence'
"$run/delete-instance.sh" > /dev/null 2> "$test_root/delete-warning"
grep -qx 'delete' "$TEST_GCLOUD_LOG"
if grep -qx -- '--quiet' "$TEST_GCLOUD_LOG"; then fail 'instance deletion bypassed confirmation'; fi
[[ ! -e "$test_root/should-not-exist" ]] || fail 'launch metadata was executed'
mv "$run" "$test_root/moved run"
run="$test_root/moved run"
"$run/status.sh" > /dev/null || fail 'helpers depend on their original directory'
mv "$run/launch.env" "$test_root/saved.env"
ln -s "$test_root/saved.env" "$run/launch.env"
if "$run/status.sh" > /dev/null 2> "$test_root/symlink-error"; then fail 'symlink metadata accepted'; fi

# Exercise the complete launch handoff with simulated remote operations only.
# The commands are recorded, never executed on a real cloud host.
repo="$test_root/repo"
mkdir -p "$repo/lib" "$repo/scripts" "$repo/cloud" "$test_root/entry"
cp "$project_dir/launch-cloud-judging.sh" "$project_dir/judging-status.sh" "$repo/"
cp "$project_dir"/lib/*.sh "$repo/lib/"
cp "$project_dir/scripts/cloud-run-control.sh" "$project_dir/scripts/watch-cloud-judging.sh" \
  "$project_dir/scripts/run-in-tmux.sh" "$repo/scripts/"
cp "$project_dir/cloud/bootstrap-ubuntu.sh" "$project_dir/cloud/fetch-enwik9.sh" "$repo/cloud/"
cat > "$repo/provision-gcp-instance.sh" <<'EOF'
#!/usr/bin/env bash
echo us-east1-b
EOF
cat > "$test_root/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$test_root/bin/gcloud" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >> "$TEST_GCLOUD_LOG"
if [[ "$1 $2" == 'compute scp' ]]; then
  args=("$@")
  source_file="${args[-2]}" destination="${args[-1]#*:}"
  if [[ "$destination" == "$TEST_REMOTE_HOME/"* ]]; then
    mkdir -p "$(dirname "$destination")"
    cp "$source_file" "$destination"
  fi
elif [[ "$1 $2" == 'compute ssh' ]]; then
  command_text=""
  for arg in "$@"; do [[ "$arg" != --command=* ]] || command_text="${arg#--command=}"; done
  case "$command_text" in
    'printf "%s\n" "$HOME"') echo "$TEST_REMOTE_HOME" ;;
    sha256sum\ *) sha256sum -- "${command_text#sha256sum }" ;;
    *rev-parse\ HEAD*) printf '%040d\n' 1 ;;
    *'sudo bash '*bootstrap*) [[ "${TEST_FAIL_BOOTSTRAP:-false}" != true ]] || exit 55 ;;
    *fetch-enwik9-*) echo 159b85351e5f76e60cbe32e04c677847a9ecba3adc79addab6f4c6c7aa3744bc ;;
    *hutter-prize-tmux-*)
      record="$(find "$TEST_REPO/Results" -name launch.env | sort | tail -n1)"
      grep -qx 'launch_phase=starting' "$record"
      grep -qx 'workflow_attempted=true' "$record"
      [[ -x "$(dirname "$record")/connect.sh" ]] || exit 92
      printf '%s\n' "$command_text" > "$TEST_TMUX_COMMAND"
      ;;
  esac
else
  echo 'unexpected cloud operation' >&2
  exit 93
fi
EOF
chmod +x "$test_root/bin/"* "$repo/provision-gcp-instance.sh"
cat > "$test_root/entry/entry.env" <<'EOF'
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
printf 'test source placeholder\n' > "$test_root/entry/source.tar.gz"
export TEST_REMOTE_HOME="$test_root/remote" TEST_REPO="$repo" TEST_TMUX_COMMAND="$test_root/tmux-command"
"$repo/launch-cloud-judging.sh" --compression-only --project example-project \
  --instance-name hpja-fixture "$test_root/entry" > "$test_root/launch.stdout" 2> "$test_root/launch.stderr"
record="$(find "$repo/Results" -name launch.env -print -quit)"
[[ -n "$record" ]] || fail 'launcher did not save the run record'
grep -qx 'launch_phase=started' "$record"
grep -q '^remote_results=.*/Results/cloud-run-' "$record"
grep -q -- '--results.*Results/cloud-run-' "$TEST_TMUX_COMMAND" || fail 'remote run scope not passed to orchestrator'
grep -q '^Run commands:' "$test_root/launch.stdout" || fail 'launcher did not direct operator to saved commands'
if grep -Eq '^(Attach:|Watch:|Status:|Copy results:|Delete when finished:)' "$test_root/launch.stdout"; then
  fail 'launcher still prints volatile complex command lines'
fi
[[ -f "$(dirname "$record")/README.txt" ]] || fail 'saved command instructions missing'

if TEST_FAIL_BOOTSTRAP=true "$repo/launch-cloud-judging.sh" --compression-only \
    --project example-project --instance-name hpja-failed "$test_root/entry" \
    > "$test_root/failed.stdout" 2> "$test_root/failed.stderr"; then
  fail 'simulated bootstrap failure was ignored'
fi
failed_record="$(grep -l '^instance_name=hpja-failed$' "$repo"/Results/*/launch.env)"
grep -qx 'launch_phase=setup_failed' "$failed_record"
grep -qx 'workflow_attempted=false' "$failed_record"
grep -q 'Run commands and connection details:' "$test_root/failed.stderr"
"$(dirname "$failed_record")/status.sh" > "$test_root/setup-status"
grep -q 'Cloud setup: setup_failed' "$test_root/setup-status"
echo 'cloud run control tests passed (simulated gcloud; no billable infrastructure)'
