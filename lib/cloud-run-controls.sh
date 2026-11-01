#!/usr/bin/env bash

# Keep the trusted tools with the run, rather than relying on terminal history
# or a future version of the operator's repository checkout.
hp_cloud_run_controls_create() (
  set -Eeuo pipefail
  umask 077
  local repo="$1" directory="$2" action name
  mkdir -p -- "$(dirname -- "$directory")"
  mkdir -- "$directory"
  mkdir -- "$directory/_tools"
  cp -- "$repo/scripts/cloud-run-control.sh" "$directory/_tools/"
  cp -- "$repo/judging-status.sh" "$directory/_tools/"
  cp -- "$repo/scripts/watch-cloud-judging.sh" "$directory/_tools/"
  chmod 0500 -- "$directory/_tools/"*.sh
  for action in connect attach status watch report notify logs fetch-results delete-instance; do
    name="$directory/$action.sh"
    {
      printf '%s\n' '#!/usr/bin/env bash' 'set -Eeuo pipefail'
      printf '%s\n' 'run_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"'
      printf 'exec bash "$run_dir/_tools/cloud-run-control.sh" %q "$@"\n' "$action"
    } > "$name"
    chmod 0500 -- "$name"
  done
  cat > "$directory/README.txt" <<'EOF'
Commands for this cloud launch (run them from any working directory):

  connect.sh          Open an SSH shell on the instance.
  attach.sh           Attach to the workflow's tmux session.
  status.sh           Show this run's stages, measurements and progress.
  watch.sh [SECONDS]  Refresh status (default: every 60 seconds; Ctrl-C stops).
  report.sh           Print the compact measurements/checksum report.
  notify.sh [SECONDS] Watch for operator-attention notices (default: 60 seconds).
  logs.sh             Follow this run's workflow log (Ctrl-C stops following).
  fetch-results.sh    Download this run only to downloads/results.tar.gz.
  delete-instance.sh  Delete the instance, with gcloud's confirmation prompt.

Each script supports --help. Connection details are saved in launch.env and
are parsed as data, never executed. Trusted status tools are saved in _tools/,
so these commands also work after moving this entire directory or updating
the judging-system checkout. gcloud and your local credentials are required;
gcloud credentials are not copied here or to the cloud host. Launch metadata
may include private entrant download URLs; keep this directory private.

During setup, status.sh reports setup state. Detailed workflow status becomes
available after execution starts. Instance charges continue after completion
or setup failure. Retrieve the results before deleting the instance: Local SSD
contents are ephemeral. An older launch's deletion command also deletes any
later work on the same retained instance; review the confirmation carefully.

fetch-results.sh includes archives and may be large. It uses privileged remote
reads when available, validates the download, and replaces its previous bundle
only after success. It never extracts or executes downloaded entrant content.
Use report.sh or status.sh for a small query without downloading archives.
Full results/logs may contain private entrant material; do not publish this
directory or its downloads without review.
EOF
  chmod 0400 -- "$directory/README.txt"
)
