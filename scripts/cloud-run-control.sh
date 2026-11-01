#!/usr/bin/env bash
set -Eeuo pipefail

# Copied into RUN_DIR/_tools by the launcher; launch.env remains untrusted data.
readonly tools_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly run_dir="$(dirname -- "$tools_dir")"
readonly record="$run_dir/launch.env"
action="${1:-}"
(( $# == 0 )) || shift
usage() {
  printf 'Usage: %s.sh' "$action"
  case "$action" in watch|notify) printf ' [SECONDS]' ;; status) printf ' [STATUS_OPTIONS]' ;; esac
  printf '\n\nRun-specific cloud command; connection details are in launch.env.\n'
  case "$action" in
    connect) echo 'Open an SSH shell.' ;;
    attach) echo 'Attach to the workflow tmux session.' ;;
    status) echo 'Show stages and progress; accepts judging-status.sh options.' ;;
    watch) echo 'Refresh status every SECONDS (default: 60); Ctrl-C stops watching.' ;;
    report) echo 'Print the compact numeric/checksum report without downloading archives.' ;;
    notify) echo 'Watch for operator attention every SECONDS (default: 60).' ;;
    logs) echo 'Follow the workflow log; Ctrl-C stops following, not the workflow.' ;;
    fetch-results) echo 'Download this run to downloads/results.tar.gz; never extract it.' ;;
    delete-instance) echo 'Delete the instance after gcloud confirmation. Retrieve results first.' ;;
  esac
}
die() { printf 'error: %s\n' "$*" >&2; exit 2; }
case "$action" in
  -h|--help)
    printf 'Usage: cloud-run-control.sh ACTION [OPTIONS]\n\nInternal dispatcher copied into a cloud launch directory; use its named scripts.\n'
    exit 0 ;;
  connect|attach|status|watch|report|notify|logs|fetch-results|delete-instance) ;;
  *) printf 'error: unknown cloud run command\n\nUsage: cloud-run-control.sh ACTION [OPTIONS]\n' >&2; exit 2 ;;
esac
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then usage; exit 0; fi
interval=60
case "$action" in
  watch|notify)
    (( $# <= 1 )) || { usage >&2; exit 2; }
    interval="${1:-60}"
    [[ "$interval" =~ ^[1-9][0-9]*$ ]] || die 'SECONDS must be a positive integer'
    ;;
  status) ;;
  *) (( $# == 0 )) || { usage >&2; exit 2; } ;;
esac
value() {
  awk -v key="$1" 'index($0,key "=")==1 {print substr($0,length(key)+2); exit}' "$record"
}
[[ -f "$record" && -r "$record" && ! -L "$record" ]] || die 'missing regular launch.env'
instance="$(value instance_name)" project="$(value project)" zone="$(value zone)"
[[ "$instance" =~ ^[a-z]([-a-z0-9]{0,61}[a-z0-9])?$ \
    && "$project" =~ ^[A-Za-z0-9][A-Za-z0-9:.-]*$ ]] || die 'invalid instance/project in launch.env'
[[ "$zone" =~ ^[a-z0-9-]+$ ]] || die 'the instance zone is not recorded; see launch.env for setup state'
command -v gcloud >/dev/null || die 'gcloud is not installed or is not in PATH'
connection=("$instance" "--zone=$zone" "--project=$project")
case "$action" in
  connect) exec gcloud compute ssh "${connection[@]}" ;;
  delete-instance)
    echo 'Retrieve results first. Deleting this instance destroys its Local SSD and stops all its work.' >&2
    exec gcloud compute instances delete "${connection[@]}"
    ;;
  attach)
    socket="$(value tmux_socket)" session="$(value tmux_session)"
    [[ "$socket" =~ ^[A-Za-z0-9_.-]+$ && "$session" =~ ^[A-Za-z0-9_.-]+$ ]] || die 'invalid tmux metadata'
    printf -v remote_command 'tmux -L %q attach-session -t %q' "$socket" "$session"
    exec gcloud compute ssh "${connection[@]}" -- -t "$remote_command"
    ;;
esac
phase="$(value launch_phase)"
if [[ "$(value workflow_attempted)" != true ]]; then
  printf 'Cloud setup: %s; workflow has not been launched. Use connect.sh to inspect the instance.\n' "$phase"
  exit 0
fi
results="$(value remote_results)" log="$(value remote_log)"
[[ "$results" == /* && "$results" != / && "$results" != *$'\n'* \
    && "$log" == "$results/workflow.log" ]] || die 'invalid run-specific remote paths'
case "$action" in
  status) exec bash "$tools_dir/judging-status.sh" --launch-record "$record" "$@" ;;
  watch) exec bash "$tools_dir/judging-status.sh" --launch-record "$record" --watch "$interval" ;;
  report) exec bash "$tools_dir/judging-status.sh" --launch-record "$record" --report-only ;;
  notify)
    exec bash "$tools_dir/watch-cloud-judging.sh" --instance "$instance" \
      --zone "$zone" --project "$project" --remote-log "$log" --poll-seconds "$interval"
    ;;
  logs)
    printf -v remote_command 'tail -n 40 -F -- %q' "$log"
    exec gcloud compute ssh "${connection[@]}" --quiet --command="$remote_command"
    ;;
  fetch-results)
    umask 077
    [[ ! -L "$run_dir/downloads" ]] || die 'refusing symlink downloads directory'
    mkdir -p -- "$run_dir/downloads"
    temporary="$(mktemp "$run_dir/downloads/.results.XXXXXX")"
    trap 'rm -f -- "$temporary"' EXIT
    printf -v tar_command 'tar -C %q -czf - -- %q' "$(dirname -- "$results")" "$(basename -- "$results")"
    remote_command="if sudo -n true 2>/dev/null; then sudo -n $tar_command; else $tar_command; fi"
    gcloud compute ssh "${connection[@]}" --quiet --command="$remote_command" > "$temporary"
    tar -tzf "$temporary" >/dev/null
    chmod 0600 -- "$temporary"
    mv -f -- "$temporary" "$run_dir/downloads/results.tar.gz"
    trap - EXIT
    printf 'Saved: %s/downloads/results.tar.gz (not extracted)\n' "$run_dir"
    ;;
esac
