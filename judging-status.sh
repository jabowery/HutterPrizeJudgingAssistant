#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: ./judging-status.sh [OPTIONS] [RUN_DIR_OR_RESULTS_DIR]

Summarize judging stages, last observed progress, and artifact availability.
With a Results directory (default: ./Results), select the latest full run.
No archives are downloaded and no contestant program is executed.

Options:
  --instance NAME        Read the cloud host through gcloud compute ssh
  --zone ZONE            Required with --instance
  --project PROJECT      Required with --instance
  --remote-results DIR   Cloud Results directory (default: ~/HutterPrizeJudgingAssistant/Results)
  --launch-record FILE   Use connection details from a cloud-launch-*.env record
  --log FILE             Explicit workflow log, useful for older runs
  --watch SECONDS        Refresh repeatedly (e.g. --watch 60)
  -h, --help             Show this help

Run sudo ./judging-status.sh RUN_DIR if live evidence is not readable locally.
Cloud queries use passwordless sudo when available, otherwise ordinary reads.
Copied results are snapshots, not proof that a remote process is still running.
EOF
}
usage_error() { printf 'error: %s\n\n' "$*" >&2; usage >&2; exit 2; }
# Never execute .env content, including cloud launch records.
value() {
  [[ -f "$1" && -r "$1" && ! -L "$1" ]] || return 0
  awk -v key="$2" 'index($0, key "=") == 1 {print substr($0, length(key)+2); exit}' "$1"
}
instance= zone= project= remote_results= launch_record= log= interval= root= positional=false
while (( $# )); do
  case "$1" in
    --instance|--zone|--project|--remote-results|--launch-record|--log|--watch)
      (( $# >= 2 )) || usage_error "$1 requires a value"
      case "$1" in
        --instance) instance="$2" ;; --zone) zone="$2" ;; --project) project="$2" ;;
        --remote-results) remote_results="$2" ;; --launch-record) launch_record="$2" ;;
        --log) log="$2" ;; --watch) interval="$2" ;;
      esac
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --*) usage_error "unknown option: $1" ;;
    *) [[ "$positional" == false ]] || usage_error "only one results path is accepted"
       root="$1"; positional=true; shift ;;
  esac
done
[[ -z "$interval" || "$interval" =~ ^[1-9][0-9]*$ ]] || usage_error "--watch requires positive seconds"
if [[ -n "$launch_record" ]]; then
  [[ -r "$launch_record" && ! -L "$launch_record" ]] || usage_error "cannot read launch record"
  instance="${instance:-$(value "$launch_record" instance_name)}"
  zone="${zone:-$(value "$launch_record" zone)}"
  project="${project:-$(value "$launch_record" project)}"
  log="${log:-$(value "$launch_record" remote_log)}"
  remote_results="${remote_results:-${log%/*}}"
fi
if [[ -n "$instance" ]]; then
  [[ "$instance" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || usage_error "invalid instance"
  [[ "$zone" =~ ^[A-Za-z0-9-]+$ && "$project" =~ ^[A-Za-z0-9][A-Za-z0-9:.-]*$ ]] \
    || usage_error "--instance requires valid --zone and --project"
  [[ "$positional" == false ]] || usage_error "use --remote-results for cloud paths"
  command -v gcloud >/dev/null || usage_error "gcloud is not installed"
elif [[ -n "$zone$project$remote_results$launch_record" ]]; then
  usage_error "cloud options require --instance or a valid --launch-record"
fi

latest_file() {
  [[ -d "$1" ]] || return 0
  find -P "$1" -type f -name "$2" -print 2>/dev/null | LC_ALL=C sort | tail -n1
}
emit_env() {
  printf '@%s\n' "$1"
  [[ -r "$2" && ! -L "$2" ]] && cat -- "$2"
  return 0
}
local_snapshot() {
  local selected="${root:-./Results}" parent state lifecycle observation pid ticks current_boot
  local phase file run_dir sample candidate best_sample live_file pointer
  [[ -d "$selected" && "$selected" != *$'\n'* ]] || usage_error "invalid results directory: $selected"
  if [[ "$(basename -- "$selected")" != full-* ]]; then
    selected="$(find -P "$selected" -mindepth 1 -maxdepth 1 -type d -name 'full-*' -print | LC_ALL=C sort | tail -n1)"
  fi
  [[ -n "$selected" ]] || usage_error "no full judging runs found"
  selected="$(realpath -- "$selected")"
  parent="$(dirname -- "$selected")"
  state="$selected/judging-state.env"
  lifecycle="$(value "$state" lifecycle)"
  observation='Snapshot / last recorded evidence; process activity is not confirmed'
  if [[ "$lifecycle" == exited ]]; then
    observation="Orchestrator exited (code $(value "$state" exit_code))"
  elif [[ "$lifecycle" == running ]]; then
    pid="$(value "$state" orchestrator_pid)"
    ticks="$(value "$state" orchestrator_start_ticks)"
    current_boot="$(< /proc/sys/kernel/random/boot_id)"
    if [[ "$pid" =~ ^[1-9][0-9]*$ && "$ticks" =~ ^[0-9]+$ \
        && "$(value "$state" host_boot_id)" == "$current_boot" \
        && -r "/proc/$pid/stat" \
        && "$(awk '{print $22}' "/proc/$pid/stat")" == "$ticks" ]]; then
      observation='Orchestrator is active on this host'
    fi
  fi
  printf 'Run: %s\nObservation: %s\n' "$selected" "$observation"
  {
    emit_env state "$state"
    emit_env final "$selected/final.env"
    emit_env attention "$selected/operator-attention.env"
    for phase in calibration dependencies build; do
      case "$phase" in
        calibration) file="$(latest_file "$selected/$phase" calibration.env)" ;;
        dependencies) file="$(latest_file "$selected/$phase" dependency-image.env)" ;;
        build) file="$(latest_file "$selected/$phase" build.env)" ;;
      esac
      printf '@stage\n%s=%s\n' "$phase" "$([[ -n "$file" ]] && echo DONE || echo NOT_RECORDED)"
    done
    printf '@stage\n'
    [[ ! -f "$selected/storage-preflight/summary.env" ]] || printf 'storage-preflight=DONE\n'
    [[ ! -f "$selected/host-security.env" ]] || printf 'host-security=DONE\n'
    [[ -z "$(latest_file "$selected/submission-package" package.env)" ]] || printf 'submission-package=DONE\n'
    for phase in submitted-decompression compression generated-decompression; do
      # Select the latest attempt, not an earlier cancelled or restarted worker.
      run_dir=""
      if [[ -d "$selected/$phase" ]]; then
        run_dir="$(find -P "$selected/$phase" -mindepth 1 -maxdepth 1 -type d -print | LC_ALL=C sort | tail -n1)"
      fi
      if [[ "$phase" == compression ]]; then
        file="$(latest_file "$run_dir" compression.env)"
        emit_env "$phase" "$file"
      else
        file="$run_dir/summary.tsv"
        printf '@%s\n' "$phase"
        if [[ -r "$file" ]]; then
          awk -F '\t' 'NR > 1 && NF >= 2 {print "status=" $2}' "$file"
        fi
      fi
      [[ -z "$run_dir" ]] || printf 'attempt=recorded\n'
      file="$(latest_file "$run_dir" gnu_time_elapsed_seconds)"
      if [[ -r "$file" ]]; then printf 'completed_wall_seconds=%s\n' "$(< "$file")"; fi
      best_sample=0; live_file=""
      for pointer in "$selected/live-status/$phase.path" "$selected"/adaptive-control/*status.path; do
        case "$phase:$pointer" in
          submitted-decompression:*/compressor-status.path|submitted-decompression:*/serial-compressor-status.path|compression:*/decompressor-status.path|compression:*/serial-decompressor-status.path|generated-decompression:*/adaptive-control/*) continue ;;
        esac
        [[ -r "$pointer" && ! -L "$pointer" ]] || continue
        IFS= read -r candidate < "$pointer" || continue
        [[ "$candidate" == /*/report/runtime-status.env ]] || continue
        sample="$(value "$candidate" sample_epoch)"
        [[ "$sample" =~ ^[0-9]+$ ]] || continue
        if (( sample > best_sample )); then best_sample="$sample"; live_file="$candidate"; fi
      done
      if [[ -z "$live_file" ]]; then live_file="$(latest_file "$run_dir" runtime-status.env)"; fi
      emit_env "$phase-live" "$live_file"
    done
    printf '@artifacts\n'
    find -P "$selected/execution/submitted" "$selected/generated" -maxdepth 1 -type f \
      -printf '%p\t%s\n' 2>/dev/null || true
    # Older runs have no orchestration metadata. Extract only the last trusted-
    # format status for each output from the matching log, never transfer logs.
    file="$log"
    if [[ -z "$file" ]]; then
      for candidate in "$parent"/cloud-*.log; do
        [[ -r "$candidate" ]] || continue
        if grep -Fq -- "$(basename -- "$selected")" "$candidate"; then file="$candidate"; break; fi
      done
    fi
    if [[ -r "$file" ]]; then
      printf '@log\n'
      awk '/^STATUS: / {for(i=1;i<=NF;i++) if($i ~ /^output=/) {split($i,a,"="); last[a[2]]=$0}} END {for(k in last) print last[k]}' "$file"
    fi
  } | LC_ALL=C tr -d '\000-\010\013-\037\177' | LC_ALL=C awk -v now="$(date +%s)" '
    function hms(n, sign) { sign=n<0?"-":""; n=int(n<0?-n:n); return sprintf("%s%02d:%02d:%02d",sign,int(n/3600),int(n%3600/60),n%60) }
    /^@/ {section=substr($0,2); next}
    section=="artifacts" {split($0,a,"\t"); artifacts[a[1]]=a[2]; next}
    section=="log" {logs[++nlog]=$0; next}
    index($0,"=") {p=index($0,"="); data[section,substr($0,1,p-1)]=substr($0,p+1)}
    END {
      print "Stage                          State"
      stages[1]="storage-preflight"; stages[2]="host-security"; stages[3]="submission-package";
      stages[4]="calibration"; stages[5]="dependencies"; stages[6]="build";
      stages[7]="submitted-decompression"; stages[8]="compression"; stages[9]="generated-decompression"
      for(i=1;i<=9;i++) {
        s=stages[i]; status=data[s,"status"]
        if(i<=6) status=data["stage",s]
        if(status=="") status="NOT_RECORDED"
        if(s=="submitted-decompression" && data["state","source_only"]=="true") status="SKIPPED (source-only)"
        if(s=="generated-decompression" && data["final","second_decompression"]=="skipped_identical") status="SKIPPED (byte-identical)"
        if(status=="NOT_RECORDED" && data[s,"attempt"]=="recorded") status="NO COMPLETED VERDICT"
        failed=data["final","failed_stage"]; gsub(/_/,"-",failed)
        if(status !~ /^FAIL/ && (failed==s || (s=="build" && failed=="compressor-build") || (s=="calibration" && failed=="geekbench"))) status="FAIL (see final verdict)"
        printf "%-30s %s\n",s,status
        if(data[s,"completed_wall_seconds"]!="") print "  Measured wall time: " hms(data[s,"completed_wall_seconds"])
      }
      if(data["state","current_stage"]!="") print "Orchestrator stage: " data["state","current_stage"]
      if(data["final","technical_verdict"]!="") print "Verdict: " data["final","technical_verdict"]
      if(data["final","failed_stage"]!="") print "Failed stage: " data["final","failed_stage"] " — " data["final","reason"]
      if(data["attention","reason"]!="") print "OPERATOR ATTENTION: " data["attention","phase"] " — " data["attention","reason"]
      for(i=7;i<=9;i++) {
        if(data[stages[i],"status"]!="") continue
        s=stages[i] "-live"; if(data[s,"sample_epoch"]=="") continue
        print "\n" stages[i] " (last sample age " hms(now-data[s,"sample_epoch"]) "):"
        print "  Wall elapsed " hms(data[s,"wall_elapsed_seconds"]) "; allowance " hms(data[s,"allowance_seconds"])
        print "  Output " data[s,"output_bytes"] " / " data[s,"expected_output_bytes"] " bytes"
        basis=data[s,"projection_basis"]; prefix=basis=="read-cursor"?"read":"output"
        if(data[s,"projection_available"]=="yes") {
          print "  Linear projected total " hms(data[s,prefix "_projected_total_seconds"]) "; margin " hms(data[s,prefix "_projected_margin_seconds"]) " (basis: " basis ")"
        } else print "  Projection unavailable — completion time cannot be estimated"
      }
      if(nlog) {
        print "\nWorkflow log telemetry (last observed, may be stale):"
        for(i=1;i<=nlog;i++) {
          delete fields; count=split(logs[i],words," ")
          for(j=1;j<=count;j++) {p=index(words[j],"="); if(p) fields[substr(words[j],1,p-1)]=substr(words[j],p+1)}
          completed=0
          for(j=7;j<=9;j++) if(data[stages[j],"status"]!="" && data[stages[j] "-live","wall_elapsed_seconds"]!="" && fields["wall-elapsed"]==hms(data[stages[j] "-live","wall_elapsed_seconds"])) completed=1
          if(completed) continue
          print "  " fields["output"] "; elapsed " fields["wall-elapsed"] "; remaining " fields["wall-remaining"]
          print "    Output-based progress " fields["linear-progress"] "; projected total " fields["linear-projected-total"] "; margin " fields["linear-projected-margin"]
          if(fields["read-linear-progress"]!="unavailable" && fields["read-linear-progress"]!="")
            print "    Read-cursor progress " fields["read-linear-progress"] "; projected total " fields["read-linear-projected-total"] "; margin " fields["read-linear-projected-margin"]
        }
      }
      print "\nArtifacts (exported files, not live output):"
      for(path in artifacts) print "  " (path ~ /\/execution\/submitted\//?"SUBMITTED":"REBUILT") " " path " — " artifacts[path] " bytes"
      if(data["state","archive_name"]!="") {
        found=0; for(path in artifacts) if(path ~ /\/generated\// && substr(path,length(path)-length(data["state","archive_name"])+1)==data["state","archive_name"]) found=1
        if(!found) print "  Rebuilt archive: not exported yet"
      }
      print "\nNOT_RECORDED means no evidence in this snapshot; it is not a failure. Projections are advisory, not qualification verdicts."
    }'
}
snapshot() {
  if [[ -z "$instance" ]]; then local_snapshot; return; fi
  local remote_command remote_path
  # Arguments belong to both branches; use shell-quoted values, never eval metadata.
  remote_path="$remote_results"
  [[ "$remote_path" != *$'\n'* && "$log" != *$'\n'* ]] || usage_error "invalid remote path"
  if [[ -n "$remote_path" ]]; then
    printf -v remote_path '%q' "$remote_path"
  else
    remote_path='"$HOME/HutterPrizeJudgingAssistant/Results"'
  fi
  printf -v remote_command 'if sudo -n true 2>/dev/null; then exec sudo -n bash -s -- %s --log %q; else exec bash -s -- %s --log %q; fi' \
    "$remote_path" "$log" "$remote_path" "$log"
  gcloud compute ssh "$instance" --zone="$zone" --project="$project" --quiet \
    --command="$remote_command" < "${BASH_SOURCE[0]}"
}
while :; do
  snapshot
  [[ -n "$interval" ]] || break
  sleep "$interval"
done
