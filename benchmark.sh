#!/usr/bin/env bash
set -Eeuo pipefail

readonly script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly -a original_argv=("$@")
source "$script_dir/lib/prize-limits.sh"
image=hutter-prize-judging:local
results_path="$script_dir/Results"
skip_build=false
results_path_created=false
run_results=""
result_dir=""

usage() {
  cat <<'EOF'
Usage: ./benchmark.sh [--image NAME] [--results DIR] [--skip-build]

Run the supplied Geekbench 5.5.1 Linux CPU benchmark inside the same Docker
runtime used for judging. The Tryout edition requires temporary Internet access
to upload its trusted result. Prints only the single-core score T on stdout;
the complete log and calibration metadata are retained under Results/.
EOF
}

die() { echo "error: $*" >&2; exit 2; }
restore_invoking_user_ownership() {
  local owner
  (( EUID == 0 )) || return 0
  [[ "${SUDO_UID:-}" =~ ^[0-9]+$ && "${SUDO_GID:-}" =~ ^[0-9]+$ ]] \
    || return 0
  owner="$SUDO_UID:$SUDO_GID"

  if [[ -n "$run_results" && -d "$run_results" && ! -L "$run_results" ]]; then
    chown -R -- "$owner" "$run_results" >/dev/null 2>&1 || true
  fi
  if [[ "$results_path_created" == true \
      && -d "$results_path" && ! -L "$results_path" ]]; then
    chown -- "$owner" "$results_path" >/dev/null 2>&1 || true
  fi
}
require_docker_daemon() {
  local diagnostic
  command -v docker >/dev/null \
    || die "Docker is not installed or is not in PATH"
  if diagnostic="$(timeout 30 docker info --format '{{.ServerVersion}}' 2>&1)"; then
    return
  fi

  if [[ "$diagnostic" == *"permission denied"* \
      || "$diagnostic" == *"Permission denied"* ]]; then
    if (( EUID != 0 )); then
      command -v sudo >/dev/null \
        || die "Docker access requires root, but sudo is not installed or is not in PATH"
      echo "Docker daemon access requires elevation; invoking sudo..." >&2
      exec sudo -- "$script_dir/benchmark.sh" "${original_argv[@]}"
      die "sudo could not re-execute benchmark.sh"
    fi
    printf 'error: root cannot access the Docker daemon:\n%s\n' "$diagnostic" >&2
  else
    printf 'error: Docker daemon is unavailable:\n%s\n' "$diagnostic" >&2
  fi
  exit 2
}
trap restore_invoking_user_ownership EXIT

while (( $# > 0 )); do
  case "$1" in
    --image) (( $# >= 2 )) || die "$1 requires a value"; image="$2"; shift 2 ;;
    --results) (( $# >= 2 )) || die "$1 requires a value"; results_path="$2"; shift 2 ;;
    --skip-build) skip_build=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_docker_daemon
if [[ "$skip_build" == true ]]; then
  docker image inspect "$image" >/dev/null || die "Docker image does not exist: $image"
else
  docker build --tag "$image" "$script_dir" >&2
fi

[[ -e "$results_path" ]] || results_path_created=true
mkdir -p -- "$results_path"
results_path="$(realpath -- "$results_path")"
readonly stamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
run_results="$results_path/$stamp"
result_dir="$run_results/geekbench5"
mkdir -p -- "$result_dir"
readonly log_file="$result_dir/geekbench.log"

echo "Running trusted Geekbench calibration with temporary network access..." >&2
set +e
docker run --rm \
  --network bridge \
  --read-only \
  --memory "$HP_EXECUTION_RAM_BYTES" \
  --memory-swap "$HP_EXECUTION_RAM_BYTES" \
  --pids-limit 4096 \
  --cap-drop ALL \
  --security-opt no-new-privileges=true \
  --user 65532:65532 \
  --env HOME=/work \
  --workdir /work \
  --tmpfs /work:rw,nosuid,nodev,size=1073741824,uid=65532,gid=65532,mode=700 \
  "$image" \
  /opt/geekbench/Geekbench-5.5.1-Linux/geekbench5 --cpu \
  2>&1 | tee "$log_file" >&2
benchmark_exit=${PIPESTATUS[0]}
set -e
(( benchmark_exit == 0 )) || die "Geekbench exited with status $benchmark_exit (see $log_file)"

extract_text_score() {
  awk '
    BEGIN { previous_number = "" }
    tolower($0) ~ /single-core score/ {
      for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/) { print $i; exit }
      if (previous_number != "") { print previous_number; exit }
      getline
      for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/) { print $i; exit }
    }
    {
      value = $0
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      if (value ~ /^[0-9]+$/) previous_number = value
      else previous_number = ""
    }
  ' "$1"
}

score="$(extract_text_score "$log_file")"
score_source=geekbench_output
result_url="$(sed -nE 's#.*(https://browser\.geekbench\.com/v5/cpu/[0-9]+).*#\1#p' \
  "$log_file" | tail -1)"
result_proxy_url=""
result_evidence_file=""

if [[ ! "$score" =~ ^[1-9][0-9]*$ && -n "$result_url" ]]; then
  # Some builds print only the uploaded URL. Try the public result page; a
  # manual --geekbench-score remains available if the site blocks automation.
  page_file="$result_dir/result.html"
  if curl --fail --silent --show-error --location \
      --user-agent 'HutterPrizeJudging/1.0' "$result_url" > "$page_file"; then
    score="$(sed -nE 's/.*class="score"[^>]*>[[:space:]]*([0-9]+).*/\1/p' \
      "$page_file" | head -1)"
    score_source=official_result_page
    result_evidence_file="$page_file"
  fi
fi

if [[ ! "$score" =~ ^[1-9][0-9]*$ && -n "$result_url" ]]; then
  # Cloudflare may require an interactive browser even for a public result.
  # Jina Reader is a transparent text fetcher: retain its complete response and
  # the authoritative Geekbench URL so a human judge can independently
  # cross-check T.
  result_proxy_url="https://r.jina.ai/$result_url"
  page_file="$result_dir/result-via-jina.md"
  if curl --fail --silent --show-error --location "$result_proxy_url" > "$page_file"; then
    score="$(extract_text_score "$page_file")"
    score_source=jina_reader_of_official_result
    result_evidence_file="$page_file"
  fi
fi

[[ "$score" =~ ^[1-9][0-9]*$ ]] \
  || die "could not extract the single-core score; use the result URL with --geekbench-score: ${result_url:-not reported}"

image_id="$(docker image inspect "$image" --format '{{.Id}}')"
{
  echo "geekbench_version=5.5.1"
  echo "geekbench_archive_sha256=$(sha256sum "$script_dir/Geekbench-5.5.1-Linux.tar.gz" | awk '{print $1}')"
  echo "geekbench_single_core_score=$score"
  echo "geekbench_result_url=$result_url"
  echo "geekbench_score_source=$score_source"
  echo "geekbench_result_proxy_url=$result_proxy_url"
  if [[ -n "$result_evidence_file" ]]; then
    echo "geekbench_result_evidence_sha256=$(sha256sum "$result_evidence_file" | awk '{print $1}')"
  fi
  echo "score_type=single_core"
  echo "benchmark_cpu_limit=standard_unrestricted_cpu_run"
  echo "judging_cpu_capacity=1"
  echo "execution_environment_memory_bytes=$HP_EXECUTION_RAM_BYTES"
  echo "network_access=trusted_calibration_only"
  echo "judging_image=$image"
  echo "judging_image_id=$image_id"
  echo "docker_server_version=$(docker version --format '{{.Server.Version}}')"
  echo "calibrated_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$result_dir/calibration.env"

printf '%s\n' "$score"
