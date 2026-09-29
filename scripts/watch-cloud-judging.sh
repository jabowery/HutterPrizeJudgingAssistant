#!/usr/bin/env bash
set -Eeuo pipefail

instance=""
zone=""
project=""
remote_log=""
poll_seconds=60

usage() {
  cat <<'EOF'
Usage: ./scripts/watch-cloud-judging.sh OPTIONS

Watch a remote judging log for a trusted OPERATOR_ATTENTION record. On receipt,
ring the terminal bell, print the record, and use notify-send when available.

Options:
  --instance NAME       Required Compute Engine instance
  --zone ZONE           Required instance zone
  --project PROJECT     Required Google Cloud project
  --remote-log FILE     Required absolute remote log path
  --poll-seconds N      Default: 60
  -h, --help            Show this help
EOF
}

die() { echo "error: cloud watchdog: $*" >&2; exit 2; }
usage_error() {
  echo "error: cloud watchdog: $*" >&2
  echo >&2
  usage >&2
  exit 2
}

while (( $# > 0 )); do
  case "$1" in
    --instance) (( $# >= 2 )) || usage_error "$1 requires a value"; instance="$2"; shift 2 ;;
    --zone) (( $# >= 2 )) || usage_error "$1 requires a value"; zone="$2"; shift 2 ;;
    --project) (( $# >= 2 )) || usage_error "$1 requires a value"; project="$2"; shift 2 ;;
    --remote-log) (( $# >= 2 )) || usage_error "$1 requires a value"; remote_log="$2"; shift 2 ;;
    --poll-seconds) (( $# >= 2 )) || usage_error "$1 requires a value"; poll_seconds="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage_error "unknown option: $1" ;;
  esac
done

[[ "$instance" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || die "invalid --instance"
[[ "$zone" =~ ^[A-Za-z0-9-]+$ ]] || die "invalid --zone"
[[ "$project" =~ ^[A-Za-z0-9][A-Za-z0-9:.-]*$ ]] || die "invalid --project"
[[ "$remote_log" == /* && "$remote_log" != *$'\n'* ]] || die "invalid --remote-log"
[[ "$poll_seconds" =~ ^[1-9][0-9]*$ ]] || die "invalid --poll-seconds"
command -v gcloud >/dev/null || die "gcloud is not installed or is not in PATH"

printf -v remote_log_quoted '%q' "$remote_log"
remote_command="grep -m1 '^OPERATOR_ATTENTION:' $remote_log_quoted 2>/dev/null || true"
echo "Watching $instance:$remote_log for operator attention..." >&2
while :; do
  attention="$(gcloud compute ssh "$instance" \
    --zone="$zone" --project="$project" \
    --quiet --command="$remote_command" 2>/dev/null || true)"
  if [[ "$attention" == OPERATOR_ATTENTION:* ]]; then
    printf '\a%s\n' "$attention" >&2
    if command -v notify-send >/dev/null; then
      notify-send --urgency=critical 'Hutter Prize judging needs attention' \
        "$attention" >/dev/null 2>&1 || true
    fi
    exit 3
  fi
  sleep "$poll_seconds"
done
