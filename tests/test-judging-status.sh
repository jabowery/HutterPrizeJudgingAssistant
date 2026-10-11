#!/usr/bin/env bash
set -Eeuo pipefail
readonly project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
mkdir -p "$test_root/Results/full-20261011-test/execution/submitted" \
  "$test_root/Results/full-20261011-test/generated" \
  "$test_root/Results/full-20261011-test/live-status" \
  "$test_root/Results/full-20261011-test/submitted-decompression/20261010" \
  "$test_root/Results/full-20261011-test/compression/20261011" \
  "$test_root/work/report" "$test_root/bin"
run_results="$test_root/Results/full-20261011-test"
source_only=false HP_ARCHIVE=archive9 HP_COMPRESSOR=comp9
source "$project_dir/lib/judging-state.sh"
hp_judging_state_write compression
[[ "$(stat -c %a "$run_results/judging-state.env")" == 444 ]] || fail 'state is not read-only'
printf 'reference\n' > "$run_results/execution/submitted/archive9"
printf 'compressor\n' > "$run_results/generated/comp9"
printf 'entry\tstatus\nsubmitted\tPASS\n' > "$run_results/submitted-decompression/20261010/summary.tsv"
printf '176401.80\n' > "$run_results/submitted-decompression/20261010/gnu_time_elapsed_seconds"
printf '%s\n' "$test_root/work/report/runtime-status.env" > "$run_results/live-status/compression.path"
cat > "$test_root/work/report/runtime-status.env" <<EOF
sample_epoch=$(date +%s)
wall_elapsed_seconds=120
allowance_seconds=3600
output_bytes=10
expected_output_bytes=100
projection_available=yes
projection_basis=output
output_projected_total_seconds=1200
output_projected_margin_seconds=2400
EOF
printf 'reason=$(touch %s)\nphase=compression\n' "$test_root/should-not-exist" > "$run_results/operator-attention.env"
output="$(bash "$project_dir/judging-status.sh" "$test_root/Results")"
[[ "$output" == *'Orchestrator is active on this host'* ]] || fail 'active orchestrator not identified'
[[ "$output" == *submitted-decompression*PASS*'Measured wall time: 49:00:01'* ]] || fail 'completed verdict or measured time missing'
[[ "$output" == *'Wall elapsed 00:02:00; allowance 01:00:00'* ]] || fail 'wall timing missing'
[[ "$output" == *'Linear projected total 00:20:00; margin 00:40:00'* ]] || fail 'projection missing'
[[ "$output" == *'SUBMITTED '*'/execution/submitted/archive9'* ]] || fail 'submitted artifact ambiguous'
[[ "$output" == *'Rebuilt archive: not exported yet'* ]] || fail 'missing archive ambiguous'
[[ ! -e "$test_root/should-not-exist" ]] || fail 'metadata was executed'
hp_judging_state_write compression exited 1
output="$(bash "$project_dir/judging-status.sh" "$run_results")"
[[ "$output" == *'Orchestrator exited (code 1)'* ]] || fail 'exit not reported'
# Evidence from an older run/copied tree is useful without lifecycle metadata.
mv "$run_results/judging-state.env" "$test_root/saved-state"
cat > "$test_root/Results/cloud-test.log" <<EOF
/home/remote/Results/full-20261011-test/generated/comp9
STATUS: wall-elapsed=03:20:34 wall-remaining=51:00:18 output=archive9=6291461 bytes linear-progress=6.84% linear-projected-total=48:50:08 linear-projected-margin=+05:30:44 read-linear-progress=unavailable
EOF
output="$(bash "$project_dir/judging-status.sh" "$run_results")"
[[ "$output" == *'activity is not confirmed'* ]] || fail 'snapshot mistaken for live execution'
[[ "$output" == *'archive9=6291461; elapsed 03:20:34'* ]] || fail 'older cloud telemetry not found'
[[ "$output" == *'projected total 48:50:08; margin +05:30:44'* ]] || fail 'legacy projection missing'
cat > "$test_root/bin/sudo" <<'EOF'
#!/bin/sh
exit 1
EOF
cat > "$test_root/bin/gcloud" <<'EOF'
#!/bin/bash
[[ "$1 $2" == 'compute ssh' ]] || exit 90
for arg in "$@"; do
  case "$arg" in --command=*) exec bash -c "${arg#--command=}" ;; esac
done
exit 91
EOF
chmod +x "$test_root/bin/sudo" "$test_root/bin/gcloud"
output="$(PATH="$test_root/bin:$PATH" bash "$project_dir/judging-status.sh" \
  --instance hpja-c2d8 --project test-project --zone africa-south1-a \
  --remote-results "$test_root/Results")"
[[ "$output" == *'SUBMITTED '*'/execution/submitted/archive9'* ]] || fail 'remote streamed query failed'
printf 'instance_name=hpja-c2d8\nproject=test-project\nzone=africa-south1-a\nremote_log=%s/Results/cloud-test.log\n' \
  "$test_root" > "$test_root/launch.env"
output="$(PATH="$test_root/bin:$PATH" bash "$project_dir/judging-status.sh" --launch-record "$test_root/launch.env")"
[[ "$output" == *'archive9=6291461; elapsed 03:20:34'* ]] || fail 'launch record query failed'
printf 'technical_verdict=FAIL\nfailed_stage=compression\nreason=timeout\n' > "$run_results/final.env"
output="$(bash "$project_dir/judging-status.sh" "$run_results")"
[[ "$output" == *'Verdict: FAIL'*'Failed stage: compression'* ]] || fail 'final failure missing'
printf 'status=FAIL_TIME\narchive_retained=yes\n' > "$run_results/compression/20261011/compression.env"
printf 'late archive\n' > "$run_results/generated/archive9"
printf 'technical_verdict=FAIL\nfailed_stage=compression\nreason=late run\n' > "$run_results/final.env"
output="$(bash "$project_dir/judging-status.sh" "$run_results")"
[[ "$output" == *'REBUILT '*'/generated/archive9'* ]] || fail 'retained late archive missing'
[[ "$output" == *'FAIL_TIME'* ]] || fail 'timeout verdict obscured by generic failure'
[[ "$output" != *'Rebuilt archive: not exported yet'* ]] || fail 'exported archive misreported'
printf 'source_only=true\n' > "$run_results/judging-state.env.new"
mv "$run_results/judging-state.env.new" "$run_results/judging-state.env"
output="$(bash "$project_dir/judging-status.sh" "$run_results")"
[[ "$output" == *'SKIPPED (source-only)'* ]] || fail 'source-only skip missing'
echo 'judging status tests passed'
