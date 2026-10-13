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
# A compact report must carry the actual decision numbers, without logs or
# arbitrary environment fields that may contain credentials or private paths.
mkdir -p "$run_results/submitted-decompression/20261010/submitted"
cat > "$run_results/final.env" <<'EOF'
technical_verdict=PASS
entry=Fixture
geekbench5_score=1288
time_limit_seconds=195652
memory_limit_bytes=10737418240
execution_environment_memory_bytes=17179869184
disk_limit_bytes=100000000000
submitted_archive_bytes=91913343
generated_archive_bytes=91913343
compressor_bytes=4000689
command_line_bytes=19
formal_total_bytes=95914051
previous_record_bytes=110793128
one_percent_threshold_bytes=109685196
improvement_percent=13.429604
record_status=MEETS_ONE_PERCENT
second_decompression=skipped_identical
submitted_archive_sha256=30eaf239168bd4efb4c57af09002b968308d7614d0cca619540e971fc38f4f18
generated_archive_sha256=30eaf239168bd4efb4c57af09002b968308d7614d0cca619540e971fc38f4f18
secret=DO_NOT_PUBLISH_SECRET
reason=https://example.invalid/claim?key=DO_NOT_PUBLISH_SECRET
EOF
cat > "$run_results/submitted-decompression/20261010/submitted/verification.env" <<'EOF'
output_bytes=1000000000
output_sha256=159b85351e5f76e60cbe32e04c677847a9ecba3adc79addab6f4c6c7aa3744bc
reference_sha256=159b85351e5f76e60cbe32e04c677847a9ecba3adc79addab6f4c6c7aa3744bc
verification=pass
reason=identical
EOF
# Put the completed timing and metrics together in the worker report, as in
# real results; keep the older root-level timing to exercise compatibility.
printf '176369\n' > "$run_results/submitted-decompression/20261010/submitted/gnu_time_elapsed_seconds"
printf '10649600000\n' > "$run_results/submitted-decompression/20261010/submitted/peak_rss_bytes"
printf '9000000000\n' > "$run_results/submitted-decompression/20261010/submitted/gnu_time_peak_rss_bytes"
printf '10649600000\n' > "$run_results/submitted-decompression/20261010/submitted/process_tree_peak_rss_bytes"
printf '14000000000\n' > "$run_results/submitted-decompression/20261010/submitted/cgroup_peak_memory_bytes"
printf '12000000000\n' > "$run_results/submitted-decompression/20261010/submitted/peak_disk_bytes"
cat > "$run_results/submitted-decompression/20261010/submitted/time.txt" <<'EOF'
 User time (seconds): 173531.51
 System time (seconds): 1699.94
EOF
printf 'archive_file=archive9\n' > "$run_results/submission-package.env"
mkdir -p "$run_results/submission-package"
mv "$run_results/submission-package.env" "$run_results/submission-package/package.env"
report="$(bash "$project_dir/judging-status.sh" --report-only "$run_results")"
[[ "$report" == *'Formal size S: 95914051 bytes'* ]] || fail 'formal size absent'
[[ "$report" == *'Compressor command-line options: 19 bytes'* ]] || fail 'argument charge absent'
[[ "$report" == *'Geekbench 5 single-core score: 1288'* ]] || fail 'handicap score absent'
[[ "$report" == *'Wall time: 48:59:29; allowance: 54:20:52'* ]] || fail 'completed time or limit absent'
[[ "$report" == *'Time margin: +05:21:23'* ]] || fail 'time margin absent'
[[ "$report" == *'Formal peak RSS: 9.9182128906 GiB; limit: 10 GiB'* ]] || fail 'formal RSS absent'
[[ "$report" == *'Peak allocated work storage (sampled): 12 GB; limit: 100 GB'* ]] || fail 'disk measurement absent'
[[ "$report" == *'Cgroup peak memory (includes cache, not RSS)'* ]] || fail 'cache distinction missing'
[[ "$report" == *'Output MD5 (inferred from verified canonical enwik9): e206c3450ac99950df65bf70ef61a12d'* ]] || fail 'old canonical inference not labelled'
archive_md5="$(md5sum "$run_results/execution/submitted/archive9" | awk '{print $1}')"
[[ "$report" == *"submitted archive MD5: $archive_md5"* ]] || fail 'retained archive MD5 not calculated'
[[ "$report" != *DO_NOT_PUBLISH_SECRET* && "$report" != *"$test_root"* && "$report" != *cloud-test.log* && "$report" != *claim\?key* ]] || fail 'report exposed non-report material'
report="$(PATH="$test_root/bin:$PATH" bash "$project_dir/judging-status.sh" \
  --instance hpja-c2d8 --zone africa-south1-a --project test-project \
  --remote-results "$test_root/Results" --report-only)"
[[ "$report" == *'Formal size S: 95914051 bytes'* && "$report" != *'Run: '* ]] || fail 'remote report-only flag lost'
printf 'output_md5=e206c3450ac99950df65bf70ef61a12d\n' >> "$run_results/submitted-decompression/20261010/submitted/verification.env"
report="$(bash "$project_dir/judging-status.sh" --report-only "$run_results")"
[[ "$report" == *'Output MD5: e206c3450ac99950df65bf70ef61a12d'* && "$report" != *'Output MD5 (inferred'* ]] || fail 'measured MD5 not distinguished from inference'
echo 'judging status tests passed'
