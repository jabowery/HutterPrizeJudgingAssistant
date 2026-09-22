#!/usr/bin/env bash
set -Eeuo pipefail

session=hutter-judging
history_limit=100000
workdir="$PWD"
log_file=""

usage() {
  cat <<'EOF'
Usage: ./scripts/run-in-tmux.sh [OPTIONS] -- COMMAND [ARGUMENT ...]

Configure persistent tmux scrollback, create a detached session, and run the
given command while retaining a log and exit-status file. The session remains
open at an interactive shell after the command completes.

Options:
  --session NAME             Default: hutter-judging
  --history-limit LINES      Default: 100000
  --workdir DIR              Default: current directory
  --log FILE                 Default: WORKDIR/Results/cloud-NAME.log
  -h, --help                 Show this help
EOF
}

die() {
  echo "error: tmux runner: $*" >&2
  exit 2
}

usage_error() {
  echo "error: tmux runner: $*" >&2
  echo >&2
  usage >&2
  exit 2
}

declare -a command=()
while (( $# > 0 )); do
  case "$1" in
    --session) (( $# >= 2 )) || usage_error "$1 requires a value"; session="$2"; shift 2 ;;
    --history-limit) (( $# >= 2 )) || usage_error "$1 requires a value"; history_limit="$2"; shift 2 ;;
    --workdir) (( $# >= 2 )) || usage_error "$1 requires a value"; workdir="$2"; shift 2 ;;
    --log) (( $# >= 2 )) || usage_error "$1 requires a value"; log_file="$2"; shift 2 ;;
    --) shift; command=("$@"); break ;;
    -h|--help) usage; exit 0 ;;
    *) usage_error "unknown option: $1" ;;
  esac
done

command -v tmux >/dev/null 2>&1 || die "tmux is not installed or is not in PATH"
[[ "$session" =~ ^[A-Za-z0-9_.-]+$ ]] || die "invalid session name"
[[ "$history_limit" =~ ^[1-9][0-9]*$ ]] || die "history-limit must be positive"
(( ${#command[@]} > 0 )) || usage_error "COMMAND is required after --"
[[ -d "$workdir" && ! -L "$workdir" ]] || die "invalid workdir: $workdir"
workdir="$(realpath -- "$workdir")"
log_file="${log_file:-$workdir/Results/cloud-$session.log}"
if [[ "$log_file" != /* ]]; then
  log_file="$workdir/$log_file"
fi
log_file="$(realpath -m -- "$log_file")"
mkdir -p -- "$(dirname -- "$log_file")"

tmux_fragment="$HOME/.tmux.hutter-prize.conf"
printf 'set-option -g history-limit %s\n' "$history_limit" > "$tmux_fragment"
touch "$HOME/.tmux.conf"
source_line="source-file \"$tmux_fragment\""
grep -Fqx -- "$source_line" "$HOME/.tmux.conf" \
  || printf '%s\n' "$source_line" >> "$HOME/.tmux.conf"

tmux has-session -t "$session" 2>/dev/null \
  && die "tmux session already exists: $session"

state_dir="$HOME/.local/state/hutter-prize-cloud/$session"
mkdir -p -- "$state_dir"
run_script="$state_dir/run.sh"
status_file="$state_dir/exit-status"
{
  printf '%s\n' '#!/usr/bin/env bash' 'set -uo pipefail'
  printf 'cd -- %q\n' "$workdir"
  printf "printf '%%s\\\\n' %q\n" \
    "Judging command started at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '%q ' "${command[@]}"
  printf '2>&1 | tee %q\n' "$log_file"
  printf '%s\n' 'status=${PIPESTATUS[0]}'
  printf 'printf %q "$status" > %q\n' '%s\n' "$status_file"
  printf '%s\n' \
    'printf "\nJudging command exited with status %s at %s.\n" "$status" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"' \
    'printf "Log: %s\n" '"$(printf '%q' "$log_file")" \
    'printf "This tmux session remains open for inspection. Exit the shell to close it.\n"' \
    'exec bash -i'
} > "$run_script"
chmod 0500 -- "$run_script"
rm -f -- "$status_file"

tmux source-file "$tmux_fragment" 2>/dev/null || true
printf -v runner_command '%q' "$run_script"
tmux new-session -d -s "$session" -c "$workdir" "$runner_command"
[[ "$(tmux show-options -gv history-limit)" == "$history_limit" ]] \
  || die "tmux did not apply history-limit $history_limit"

printf 'tmux_session=%s\n' "$session"
printf 'history_limit=%s\n' "$history_limit"
printf 'log_file=%s\n' "$log_file"
printf 'status_file=%s\n' "$status_file"
