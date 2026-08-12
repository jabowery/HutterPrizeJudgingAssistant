#!/usr/bin/env bash
set -Eeuo pipefail

readonly project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly test_dir="$(mktemp -d)"
trap 'rm -rf -- "$test_dir"' EXIT

mkdir -p \
  "$test_dir/work" \
  "$test_dir/Entries/Identical" \
  "$test_dir/Entries/Different" \
  "$test_dir/Entries/ParallelFail" \
  "$test_dir/Entries/HelperEscape" \
  "$test_dir/Entries/BadManifest" \
  "$test_dir/Entries/Separate"
printf 'full flow fixture\n' > "$test_dir/enwik9"
readonly fixture_size="$(stat --format='%s' "$test_dir/enwik9")"

make_entry() {
  local entry_dir="$1"
  local archive_comment="$2"
  local generated_comment="$3"
  local package_format="$4"
  local archive_mode="${5:-success}"
  local compressor_mode="${6:-success}"
  local manifest_mode="${7:-valid}"
  local package_root="$entry_dir/package-root"

  mkdir "$package_root"

  cat > "$entry_dir/archive9" <<EOF
#!/bin/sh
# $archive_comment
printf 'full flow fixture\\n' > data9
EOF
  cat > "$package_root/install.sh" <<'EOF'
#!/bin/sh
set -eu
test "$(id -u)" = 0
EOF
  cat > "$package_root/build.sh" <<EOF
#!/bin/sh
set -eu
cat > comp9 <<'COMPRESSOR'
#!/bin/sh
set -eu
test ! -e /usr/bin
test ! -e /bin/gzip
printf '%s\\n' \\
  '#!/bin/sh' \\
  '# $generated_comment' \\
  "printf 'full flow fixture\\\\n' > data9" \\
  > archive9
COMPRESSOR
chmod 0555 comp9
EOF
  if [[ "$compressor_mode" == fail ]]; then
    cat > "$package_root/build.sh" <<'EOF'
#!/bin/sh
set -eu
cat > comp9 <<'COMPRESSOR'
#!/bin/sh
exit 7
COMPRESSOR
chmod 0555 comp9
EOF
  fi
  if [[ "$compressor_mode" == helper ]]; then
    cat > "$package_root/build.sh" <<'EOF'
#!/bin/sh
set -eu
cat > actual-comp9 <<'ACTUAL'
#!/bin/sh
printf '%s\n' \
  '#!/bin/sh' \
  "printf 'full flow fixture\\n' > data9" \
  > archive9
ACTUAL
chmod 0555 actual-comp9
cat > comp9 <<'WRAPPER'
#!/bin/sh
exec ./actual-comp9 "$@"
WRAPPER
chmod 0555 comp9
EOF
  fi
  printf '%s\n' -e enwik9 enwik9.comp > "$package_root/comp9.args"
  cat > "$entry_dir/entry.env" <<'EOF'
ENTRY_FORMAT=self-extracting
EXECUTION_PLATFORM=linux-x86_64
SOURCE_PACKAGE=submission.tar.gz
COMPRESSOR=comp9
COMPRESSOR_FORMAT=executable
COMPRESSOR_ARGUMENTS=comp9.args
ARCHIVE=archive9
ARCHIVE_FORMAT=executable
DECOMPRESSED_OUTPUT=data9
EOF
  if [[ "$package_format" == zip ]]; then
    sed -i 's/SOURCE_PACKAGE=submission.tar.gz/SOURCE_PACKAGE=submission.zip/' \
      "$entry_dir/entry.env"
  fi
  if [[ "$manifest_mode" == invalid ]]; then
    printf '%s\n' 'UNDECLARED_ALIAS=other-program' >> "$entry_dir/entry.env"
  fi
  if [[ "$archive_mode" == slow ]]; then
    cat > "$entry_dir/archive9" <<'EOF'
#!/bin/sh
while :; do
  :
done
EOF
  fi

  chmod 0555 \
    "$entry_dir/archive9" "$package_root/install.sh" \
    "$package_root/build.sh"

  case "$package_format" in
    tar)
      tar --create --gzip --file "$entry_dir/submission.tar.gz" \
        --directory "$entry_dir" "$(basename -- "$package_root")"
      ;;
    zip)
      (cd "$entry_dir" && zip --quiet --recurse-paths \
        "$entry_dir/submission.zip" "$(basename -- "$package_root")")
      ;;
    *) return 2 ;;
  esac
  rm -rf -- "$package_root"

  [[ "$(find -P "$entry_dir" -mindepth 1 -maxdepth 1 -type f | wc -l)" == 3 ]]
}

make_entry "$test_dir/Entries/Identical" identical identical tar
make_entry "$test_dir/Entries/Different" submitted generated zip
make_entry "$test_dir/Entries/ParallelFail" submitted generated tar slow fail
make_entry "$test_dir/Entries/HelperEscape" identical identical tar success helper
make_entry "$test_dir/Entries/BadManifest" identical identical tar \
  success success invalid

separate_root="$test_dir/Entries/Separate/package-root"
mkdir "$separate_root"
cat > "$test_dir/Entries/Separate/decomp9" <<'EOF'
#!/bin/sh
set -eu
IFS= read -r line < "$1"
printf '%s\n' "$line" > "$2"
EOF
cp -- "$test_dir/Entries/Separate/decomp9" "$separate_root/decomp9.source"
cat > "$separate_root/install.sh" <<'EOF'
#!/bin/sh
set -eu
test "$(id -u)" = 0
EOF
cat > "$separate_root/build.sh" <<'EOF'
#!/bin/sh
set -eu
cat > comp9a <<'COMP'
#!/bin/sh
# compressor role
set -eu
IFS= read -r line < "$1"
printf '%s\n' "$line" > "$2"
COMP
cp /entry/decomp9.source decomp9
chmod 0555 comp9a decomp9
EOF
printf '%s\n' enwik9 archive9.bhm > "$separate_root/comp9a.args"
printf '%s\n' archive9.bhm data9 > "$separate_root/decomp9.args"
printf 'full flow fixture\n' > "$test_dir/Entries/Separate/archive9.bhm"
cat > "$test_dir/Entries/Separate/entry.env" <<'EOF'
ENTRY_FORMAT=separate-decompressor
EXECUTION_PLATFORM=linux-x86_64
SOURCE_PACKAGE=submission.tar.gz
COMPRESSOR=comp9a
COMPRESSOR_FORMAT=executable
COMPRESSOR_ARGUMENTS=comp9a.args
ARCHIVE=archive9.bhm
ARCHIVE_FORMAT=data
DECOMPRESSOR=decomp9
DECOMPRESSOR_FORMAT=executable
DECOMPRESSOR_ARGUMENTS=decomp9.args
DECOMPRESSED_OUTPUT=data9
EOF
chmod 0555 "$test_dir/Entries/Separate/decomp9" \
  "$separate_root/install.sh" "$separate_root/build.sh"
tar --create --gzip --file "$test_dir/Entries/Separate/submission.tar.gz" \
  --directory "$test_dir/Entries/Separate" package-root
rm -rf -- "$separate_root"

run_full() {
  local name="$1"
  shift
  "$project_dir/judge.sh" \
    --geekbench-score 8400000 \
    --expected-size "$fixture_size" \
    --memory-limit-bytes 134217728 \
    --disk-limit-bytes 104857600 \
    --disk-poll-seconds 1 \
    --record-size 1000 \
    --work-root "$test_dir/work" \
    --results "$test_dir/results-$name" \
    "$@" \
    "$test_dir/Entries/$name" "$test_dir/enwik9"
}

run_full Identical
identical_final="$(find "$test_dir/results-Identical" -name final.env -type f -print -quit)"
grep -q '^technical_verdict=PASS$' "$identical_final"
grep -q '^judge_jobs=2$' "$identical_final"
grep -q '^execution_mode=parallel$' "$identical_final"
grep -q '^archives_identical=yes$' "$identical_final"
grep -q '^second_decompression=skipped_identical$' "$identical_final"
[[ ! -e "$(dirname -- "$identical_final")/qualification-container-id" ]]
identical_compression="$(find "$test_dir/results-Identical" \
  -name compression.env -type f -print -quit)"
grep -q '^memory_limit_bytes=134217728$' "$identical_compression"
grep -q '^cgroup_memory_ceiling_bytes=1207959552$' "$identical_compression"
grep -Eq '^peak_rss_bytes=[1-9][0-9]*$' "$identical_compression"
grep -q '^command_line_bytes=22$' "$identical_compression"
grep -q '^command_line_bytes=22$' "$identical_final"

run_full Different --serial
different_final="$(find "$test_dir/results-Different" -name final.env -type f -print -quit)"
grep -q '^technical_verdict=PASS$' "$different_final"
grep -q '^judge_jobs=1$' "$different_final"
grep -q '^execution_mode=serial$' "$different_final"
grep -q '^archives_identical=no$' "$different_final"
grep -q '^second_decompression=pass$' "$different_final"
find "$test_dir/results-Different" -path '*generated-decompression*' \
  -name summary.tsv -type f | grep -q .

run_full Separate --serial
separate_final="$(find "$test_dir/results-Separate" -name final.env -type f -print -quit)"
grep -q '^technical_verdict=PASS$' "$separate_final"
grep -q '^entry_format=separate-decompressor$' "$separate_final"
grep -q '^decompressor_multiplier=2$' "$separate_final"
grep -q '^rebuilt_decompressor_identical=yes$' "$separate_final"

set +e
timeout --signal=TERM --kill-after=5 30 \
  "$project_dir/judge.sh" \
    --geekbench-score 840000 \
    --expected-size "$fixture_size" \
    --memory-limit-bytes 134217728 \
    --cgroup-headroom-bytes 134217728 \
    --disk-limit-bytes 104857600 \
    --disk-poll-seconds 1 \
    --record-size 1000 \
    --work-root "$test_dir/work" \
    --results "$test_dir/results-ParallelFail" \
    "$test_dir/Entries/ParallelFail" "$test_dir/enwik9"
parallel_fail_exit=$?
set -e

(( parallel_fail_exit != 0 && parallel_fail_exit != 124 && parallel_fail_exit != 137 ))
parallel_fail_final="$(find "$test_dir/results-ParallelFail" -name final.env -type f -print -quit)"
grep -q '^failed_stage=compression$' "$parallel_fail_final"
[[ ! -e "$(dirname -- "$parallel_fail_final")/qualification-container-id" ]]
[[ -z "$(find "$test_dir/work" -mindepth 1 -maxdepth 1 -print -quit)" ]]

# A second file produced by build.sh is deliberately not exported to the
# formal compression runtime. A tiny scored wrapper therefore cannot reach an
# uncharged helper executable.
set +e
run_full HelperEscape --serial
helper_escape_exit=$?
set -e
(( helper_escape_exit != 0 ))
helper_escape_final="$(find "$test_dir/results-HelperEscape" \
  -name final.env -type f -print -quit)"
grep -q '^failed_stage=compression$' "$helper_escape_final"

# Unknown manifest keys cannot smuggle a second executable alias into the
# trusted orchestration layer.
set +e
run_full BadManifest --serial
bad_manifest_exit=$?
set -e
(( bad_manifest_exit != 0 ))

echo "full judging flow tests passed"
