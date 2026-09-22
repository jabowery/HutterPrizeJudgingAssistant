#!/usr/bin/env bash
set -Eeuo pipefail

readonly script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/lib/entry-env.sh"
source "$script_dir/lib/entry-location.sh"
source "$script_dir/lib/gcloud-transfer.sh"

instance_name=hutter-judging-node
project=""
machine_type=t2d-standard-4
region=us-central1
boot_disk_size=200GB
boot_disk_type=pd-ssd
image_family=ubuntu-2404-lts-amd64
image_project=ubuntu-os-cloud
network=""
subnet=""
tags=""
labels=purpose=hutter-prize-judging
repo_url=https://github.com/jabowery/HutterPrizeJudgingAssistant.git
repo_ref=main
remote_repo_name=HutterPrizeJudgingAssistant
remote_work_root=/var/lib/hutter-prize-work
tmux_session=hutter-judging
tmux_history_lines=100000
geekbench_score=""
dry_run=false
declare -a requested_zones=()
declare -a positional=()
transfer_dir=""
created_instance=false
launch_complete=false
selected_zone=""

usage() {
  cat <<'EOF'
Usage: ./launch-cloud-judging.sh [OPTIONS] ENTRY_DIR [ENWIK9]

Provision and initialize a disposable Google Compute Engine host, copy and
verify the local entry and enwik9, then launch judging_assistance.sh inside a
detached tmux session with 100000 lines of scrollback. If entry.env's declared
archive is absent, the launcher automatically uses --source-only, so the
rebuilt compressor runs first and its generated archive is then decompressed.

ENTRY_DIR must be outside this repository. The sole exception is the public
examples/well-formed-entry procedural fixture. The entry is transferred to a
separate submission directory on the cloud host, never into the cloned repo.

Cloud options:
  --instance-name NAME       Default: hutter-judging-node
  --project PROJECT          Default: active gcloud project
  --machine-type TYPE        Default: t2d-standard-4
  --region REGION            Default: us-central1
  --zone ZONE                Candidate zone; repeat to set an explicit order
  --boot-disk-size SIZE      Default: 200GB
  --boot-disk-type TYPE      Default: pd-ssd
  --image-family FAMILY      Default: ubuntu-2404-lts-amd64
  --image-project PROJECT    Default: ubuntu-os-cloud
  --network NETWORK          Optional VPC network
  --subnet SUBNET            Optional VPC subnet
  --tags TAGS                Optional comma-separated network tags
  --labels LABELS            Default: purpose=hutter-prize-judging

Remote-run options:
  --repo-url URL             Judging-system Git repository
  --repo-ref REF             Branch, tag, or reachable commit (default: main)
  --remote-repo-name NAME    Directory below remote HOME
  --remote-work-root PATH    Default: /var/lib/hutter-prize-work
  --tmux-session NAME        Default: hutter-judging
  --tmux-history-lines N     Default: 100000
  --geekbench-score N        Reuse a separately verified score
  --dry-run                  Validate local inputs and print the resolved plan
  -h, --help                 Show this help

The invoking environment supplies local gcloud credentials. They are not
copied to the cloud host, and the new instance has no attached service account.
The instance is intentionally retained after setup and execution; the launcher
prints explicit attach, result-copy, and deletion commands.
EOF
}

die() {
  echo "error: $*" >&2
  exit 2
}

usage_error() {
  echo "error: $*" >&2
  echo >&2
  usage >&2
  exit 2
}

shell_join() {
  local joined="" argument quoted
  for argument in "$@"; do
    printf -v quoted '%q' "$argument"
    joined+="${joined:+ }$quoted"
  done
  printf '%s' "$joined"
}

cleanup() {
  if [[ -n "$transfer_dir" && -d "$transfer_dir" ]]; then
    rm -rf -- "$transfer_dir"
  fi
  if [[ "$created_instance" == true && "$launch_complete" != true ]]; then
    echo "Cloud setup did not complete; the instance was retained for inspection." >&2
    printf 'Delete it when finished: gcloud compute instances delete %q --zone=%q --project=%q\n' \
      "$instance_name" "$selected_zone" "$project" >&2
  fi
}
trap cleanup EXIT

while (( $# > 0 )); do
  case "$1" in
    --instance-name) (( $# >= 2 )) || usage_error "$1 requires a value"; instance_name="$2"; shift 2 ;;
    --project) (( $# >= 2 )) || usage_error "$1 requires a value"; project="$2"; shift 2 ;;
    --machine-type) (( $# >= 2 )) || usage_error "$1 requires a value"; machine_type="$2"; shift 2 ;;
    --region) (( $# >= 2 )) || usage_error "$1 requires a value"; region="$2"; shift 2 ;;
    --zone) (( $# >= 2 )) || usage_error "$1 requires a value"; requested_zones+=("$2"); shift 2 ;;
    --boot-disk-size) (( $# >= 2 )) || usage_error "$1 requires a value"; boot_disk_size="$2"; shift 2 ;;
    --boot-disk-type) (( $# >= 2 )) || usage_error "$1 requires a value"; boot_disk_type="$2"; shift 2 ;;
    --image-family) (( $# >= 2 )) || usage_error "$1 requires a value"; image_family="$2"; shift 2 ;;
    --image-project) (( $# >= 2 )) || usage_error "$1 requires a value"; image_project="$2"; shift 2 ;;
    --network) (( $# >= 2 )) || usage_error "$1 requires a value"; network="$2"; shift 2 ;;
    --subnet) (( $# >= 2 )) || usage_error "$1 requires a value"; subnet="$2"; shift 2 ;;
    --tags) (( $# >= 2 )) || usage_error "$1 requires a value"; tags="$2"; shift 2 ;;
    --labels) (( $# >= 2 )) || usage_error "$1 requires a value"; labels="$2"; shift 2 ;;
    --repo-url) (( $# >= 2 )) || usage_error "$1 requires a value"; repo_url="$2"; shift 2 ;;
    --repo-ref) (( $# >= 2 )) || usage_error "$1 requires a value"; repo_ref="$2"; shift 2 ;;
    --remote-repo-name) (( $# >= 2 )) || usage_error "$1 requires a value"; remote_repo_name="$2"; shift 2 ;;
    --remote-work-root) (( $# >= 2 )) || usage_error "$1 requires a value"; remote_work_root="$2"; shift 2 ;;
    --tmux-session) (( $# >= 2 )) || usage_error "$1 requires a value"; tmux_session="$2"; shift 2 ;;
    --tmux-history-lines) (( $# >= 2 )) || usage_error "$1 requires a value"; tmux_history_lines="$2"; shift 2 ;;
    --geekbench-score) (( $# >= 2 )) || usage_error "$1 requires a value"; geekbench_score="$2"; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    -h|--help) usage; exit 0 ;;
    --*) usage_error "unknown option: $1" ;;
    *) positional+=("$1"); shift ;;
  esac
done

(( ${#positional[@]} >= 1 && ${#positional[@]} <= 2 )) \
  || usage_error "ENTRY_DIR and optional ENWIK9 are required"
entry_dir="${positional[0]}"
enwik9_path="${positional[1]:-$script_dir/enwik9}"

[[ -d "$entry_dir" && ! -L "$entry_dir" ]] || die "invalid entry directory: $entry_dir"
[[ -f "$enwik9_path" && ! -L "$enwik9_path" ]] || die "invalid enwik9: $enwik9_path"
[[ "$(stat --format='%s' "$enwik9_path")" == 1000000000 ]] \
  || die "enwik9 must be exactly 1000000000 bytes"
entry_dir="$(realpath -- "$entry_dir")"
enwik9_path="$(realpath -- "$enwik9_path")"
hp_entry_location_require_external_or_fixture "$script_dir" "$entry_dir" \
  || exit 2
entry_name="$(basename -- "$entry_dir")"
[[ "$entry_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
  || die "entry directory basename is not portable: $entry_name"
[[ "$instance_name" =~ ^[a-z]([-a-z0-9]{0,61}[a-z0-9])?$ ]] \
  || usage_error "instance-name must be a valid Compute Engine instance name"
[[ -n "$machine_type" && -n "$region" && -n "$boot_disk_type" \
    && -n "$image_family" && -n "$image_project" ]] \
  || usage_error "machine, region, disk, and image values must not be empty"
[[ "$boot_disk_size" =~ ^[1-9][0-9]*(GB|TB)$ ]] \
  || usage_error "boot-disk-size must be a whole number of GB or TB"
for zone in "${requested_zones[@]}"; do
  [[ "$zone" =~ ^[a-z0-9-]+$ ]] || usage_error "invalid zone: $zone"
done
[[ "$remote_repo_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
  || usage_error "remote-repo-name must be a plain directory name"
[[ "$remote_work_root" == /* && "$remote_work_root" != / ]] \
  || usage_error "remote-work-root must be an absolute path other than /"
[[ "$tmux_session" =~ ^[A-Za-z0-9_.-]+$ ]] || usage_error "invalid tmux session"
[[ "$tmux_history_lines" =~ ^[1-9][0-9]*$ ]] \
  || usage_error "tmux-history-lines must be positive"
[[ -z "$geekbench_score" || "$geekbench_score" =~ ^[1-9][0-9]*$ ]] \
  || usage_error "invalid Geekbench score"
[[ -n "$repo_url" && "$repo_url" != *$'\n'* \
    && -n "$repo_ref" && "$repo_ref" != -* && "$repo_ref" != *$'\n'* ]] \
  || usage_error "repo URL and ref must be nonempty single-line values, and ref must not begin with -"

unexpected_path="$(find "$entry_dir" -mindepth 1 \
  ! -type d ! -type f -print -quit)"
[[ -z "$unexpected_path" ]] \
  || die "entry transfer rejects non-regular path: $unexpected_path"
hp_manifest_load "$entry_dir/entry.env" || exit 2
hp_manifest_require_linux || exit 2
[[ -f "$entry_dir/$HP_SOURCE_PACKAGE" \
    && ! -L "$entry_dir/$HP_SOURCE_PACKAGE" ]] \
  || die "entry is missing declared SOURCE_PACKAGE $HP_SOURCE_PACKAGE"

source_only=false
if [[ -e "$entry_dir/$HP_ARCHIVE" || -L "$entry_dir/$HP_ARCHIVE" ]]; then
  [[ -f "$entry_dir/$HP_ARCHIVE" && ! -L "$entry_dir/$HP_ARCHIVE" ]] \
    || die "declared ARCHIVE is not a regular file: $HP_ARCHIVE"
else
  source_only=true
fi

declare -a judging_command=(
  ./judging_assistance.sh --work-root "$remote_work_root"
)
[[ -z "$geekbench_score" ]] \
  || judging_command+=(--geekbench-score "$geekbench_score")
[[ "$source_only" != true ]] || judging_command+=(--source-only)
judging_command+=("../HutterPrizeSubmissions/$entry_name" ./enwik9)

if [[ "$dry_run" == true ]]; then
  printf 'instance_name=%s\n' "$instance_name"
  printf 'machine_type=%s\n' "$machine_type"
  printf 'region=%s\n' "$region"
  printf 'boot_disk_size=%s\n' "$boot_disk_size"
  printf 'entry=%s\n' "$entry_dir"
  printf 'archive_present=%s\n' "$([[ "$source_only" == true ]] && echo no || echo yes)"
  printf 'execution_mode=%s\n' "$([[ "$source_only" == true ]] && echo source_only || echo full_submission)"
  printf 'tmux_history_lines=%s\n' "$tmux_history_lines"
  printf 'judging_command=%s\n' "$(shell_join "${judging_command[@]}")"
  exit 0
fi

command -v gcloud >/dev/null 2>&1 || die "gcloud is not installed or is not in PATH"
command -v tar >/dev/null 2>&1 || die "tar is not installed or is not in PATH"
command -v sha256sum >/dev/null 2>&1 || die "sha256sum is not installed or is not in PATH"
if [[ -z "$project" ]]; then
  project="$(gcloud config get-value project 2>/dev/null)" \
    || die "could not read the active gcloud project"
fi
[[ -n "$project" && "$project" != '(unset)' ]] \
  || die "no Google Cloud project is selected; use --project"
readonly -a project_args=(--project="$project")

provision_args=(
  --name "$instance_name"
  --project "$project"
  --machine-type "$machine_type"
  --region "$region"
  --boot-disk-size "$boot_disk_size"
  --boot-disk-type "$boot_disk_type"
  --image-family "$image_family"
  --image-project "$image_project"
  --labels "$labels"
)
for zone in "${requested_zones[@]}"; do provision_args+=(--zone "$zone"); done
[[ -z "$network" ]] || provision_args+=(--network "$network")
[[ -z "$subnet" ]] || provision_args+=(--subnet "$subnet")
[[ -z "$tags" ]] || provision_args+=(--tags "$tags")
selected_zone="$("$script_dir/provision-gcp-instance.sh" "${provision_args[@]}")" \
  || die "cloud instance provisioning failed"
created_instance=true

ssh_remote() {
  gcloud compute ssh "$instance_name" "${project_args[@]}" \
    --zone="$selected_zone" --quiet --command="$1"
}

scp_remote() {
  hp_gcloud_scp_with_retry \
    "$instance_name" "$project" "$selected_zone" "$1" "$2"
}

wait_for_ssh() {
  local attempt
  for ((attempt = 1; attempt <= 90; attempt++)); do
    if ssh_remote true >/dev/null 2>&1; then
      return 0
    fi
    (( attempt % 6 != 0 )) \
      || echo "Waiting for SSH on $instance_name ($attempt/90)..." >&2
    sleep 5
  done
  return 1
}

echo "Waiting for the new instance to accept SSH..." >&2
wait_for_ssh || die "instance did not become reachable through gcloud compute ssh"
remote_home="$(ssh_remote 'printf "%s\n" "$HOME"' | tail -n 1)"
[[ "$remote_home" == /* && "$remote_home" != / && "$remote_home" != *$'\n'* ]] \
  || die "could not determine a safe remote home directory"
remote_repo="$remote_home/$remote_repo_name"

stamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
remote_bootstrap="/tmp/hutter-prize-bootstrap-$stamp.sh"
echo "Uploading and running the trusted Ubuntu bootstrap..." >&2
scp_remote "$script_dir/cloud/bootstrap-ubuntu.sh" "$remote_bootstrap"
bootstrap_command="$(shell_join sudo bash "$remote_bootstrap" \
  --work-root "$remote_work_root") && $(shell_join rm -f "$remote_bootstrap")"
ssh_remote "$bootstrap_command"

echo "Rebooting into the fully updated host kernel..." >&2
ssh_remote 'sudo reboot' >/dev/null 2>&1 || true
sleep 10
wait_for_ssh || die "instance did not return after its security-update reboot"

echo "Cloning the judging system at $repo_ref..." >&2
clone_command="$(shell_join env GIT_LFS_SKIP_SMUDGE=1 git clone "$repo_url" "$remote_repo")"
ssh_remote "$clone_command"
fetch_command="$(shell_join git -C "$remote_repo" fetch --depth=1 origin "$repo_ref")"
checkout_command="$(shell_join git -C "$remote_repo" checkout --detach FETCH_HEAD)"
lfs_command="$(shell_join git -C "$remote_repo" lfs install --local --skip-smudge)"
ssh_remote "$fetch_command && $checkout_command && $lfs_command"
remote_commit="$(ssh_remote "$(shell_join git -C "$remote_repo" rev-parse HEAD)" | tail -n 1)"
[[ "$remote_commit" =~ ^[0-9a-f]{40,64}$ ]] \
  || die "could not verify the remote judging-system commit"

remote_tmux_runner="$remote_home/hutter-prize-tmux-$stamp.sh"
tmux_runner_sha256="$(
  sha256sum -- "$script_dir/scripts/run-in-tmux.sh" | awk '{print $1}'
)"
echo "Uploading and verifying the trusted tmux runner..." >&2
scp_remote "$script_dir/scripts/run-in-tmux.sh" "$remote_tmux_runner"
remote_sha256="$(ssh_remote "$(shell_join sha256sum "$remote_tmux_runner")" \
  | awk 'END {print $1}')"
[[ "$remote_sha256" == "$tmux_runner_sha256" ]] \
  || die "trusted tmux runner SHA-256 mismatch"

transfer_dir="$(mktemp -d)"
entry_transport="$transfer_dir/entry.tar.gz"
tar -C "$(dirname -- "$entry_dir")" -czf "$entry_transport" -- "$entry_name"
entry_transport_sha256="$(sha256sum -- "$entry_transport" | awk '{print $1}')"
enwik9_sha256="$(sha256sum -- "$enwik9_path" | awk '{print $1}')"

remote_entry_transport="$remote_home/entry-$stamp.tar.gz"
remote_enwik9_upload="$remote_home/enwik9-$stamp.upload"
echo "Uploading and verifying the entry transport archive..." >&2
scp_remote "$entry_transport" "$remote_entry_transport"
remote_sha256="$(ssh_remote "$(shell_join sha256sum "$remote_entry_transport")" \
  | awk 'END {print $1}')"
[[ "$remote_sha256" == "$entry_transport_sha256" ]] \
  || die "entry transport SHA-256 mismatch"

remote_stage="$remote_home/entry-stage-$stamp"
remote_submissions="$remote_home/HutterPrizeSubmissions"
remote_entry="$remote_submissions/$entry_name"
extract_command="$(shell_join mkdir -p "$remote_stage" "$remote_submissions")"
extract_command+=" && $(shell_join tar -xzf "$remote_entry_transport" -C "$remote_stage")"
extract_command+=" && $(shell_join test -d "$remote_stage/$entry_name")"
extract_command+=" && $(shell_join rm -rf "$remote_entry")"
extract_command+=" && $(shell_join mv "$remote_stage/$entry_name" "$remote_entry")"
extract_command+=" && $(shell_join rm -f "$remote_entry_transport")"
extract_command+=" && $(shell_join rmdir "$remote_stage")"
ssh_remote "$extract_command"

echo "Uploading and verifying enwik9..." >&2
scp_remote "$enwik9_path" "$remote_enwik9_upload"
remote_sha256="$(ssh_remote "$(shell_join sha256sum "$remote_enwik9_upload")" \
  | awk 'END {print $1}')"
[[ "$remote_sha256" == "$enwik9_sha256" ]] || die "enwik9 SHA-256 mismatch"
ssh_remote "$(shell_join mv "$remote_enwik9_upload" "$remote_repo/enwik9")"

remote_log="$remote_repo/Results/cloud-$stamp-$entry_name.log"
tmux_command=(
  bash "$remote_tmux_runner"
  --session "$tmux_session"
  --history-limit "$tmux_history_lines"
  --workdir "$remote_repo"
  --log "$remote_log"
  -- "${judging_command[@]}"
)
echo "Starting the judging workflow in tmux ($tmux_session)..." >&2
ssh_remote "$(shell_join "${tmux_command[@]}")"

mkdir -p -- "$script_dir/Results"
launch_record="$script_dir/Results/cloud-launch-$stamp-$entry_name.env"
{
  echo "instance_name=$instance_name"
  echo "project=$project"
  echo "zone=$selected_zone"
  echo "machine_type=$machine_type"
  echo "boot_disk_size=$boot_disk_size"
  echo "remote_commit=$remote_commit"
  echo "tmux_runner_sha256=$tmux_runner_sha256"
  echo "entry_name=$entry_name"
  echo "entry_transport_sha256=$entry_transport_sha256"
  echo "enwik9_sha256=$enwik9_sha256"
  echo "source_only=$source_only"
  echo "tmux_session=$tmux_session"
  echo "tmux_history_lines=$tmux_history_lines"
  echo "remote_log=$remote_log"
} > "$launch_record"
launch_complete=true

printf '\nCloud judging workflow started.\n'
printf 'Instance: %s (%s, project %s)\n' "$instance_name" "$selected_zone" "$project"
printf 'Mode: %s\n' "$([[ "$source_only" == true ]] && echo source-only || echo full-submission)"
printf 'Local launch record: %s\n' "$launch_record"
printf 'Attach: gcloud compute ssh %q --zone=%q --project=%q -- -t %q\n' \
  "$instance_name" "$selected_zone" "$project" "tmux attach-session -t $tmux_session"
printf 'Copy results: gcloud compute scp --recurse --zone=%q --project=%q %q %q\n' \
  "$selected_zone" "$project" "$instance_name:$remote_repo/Results" ./
printf 'Delete when finished: gcloud compute instances delete %q --zone=%q --project=%q\n' \
  "$instance_name" "$selected_zone" "$project"
