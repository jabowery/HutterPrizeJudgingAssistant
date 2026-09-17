#!/usr/bin/env bash
set -Eeuo pipefail

readonly project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly test_dir="$(mktemp -d)"
trap 'rm -rf -- "$test_dir"' EXIT

command -v cc >/dev/null || {
  echo "error: C compiler is required for the dependency-runtime test" >&2
  exit 2
}

mkdir -p "$test_dir/entry" "$test_dir/work"
cat > "$test_dir/runtime-library.c" <<'EOF'
#include <stdio.h>

int write_fixture_output(void) {
  FILE *output = fopen("data9", "wb");
  if (output == NULL) return 1;
  if (fputs("install-provided runtime library\n", output) < 0) return 1;
  return fclose(output) == 0 ? 0 : 1;
}
EOF
cat > "$test_dir/archive.c" <<'EOF'
int write_fixture_output(void);
int main(void) { return write_fixture_output(); }
EOF
cc -shared -fPIC -Wl,-soname,libhutter-fixture.so.1 \
  "$test_dir/runtime-library.c" -o "$test_dir/libhutter-fixture.so.1"
ln -s libhutter-fixture.so.1 "$test_dir/libhutter-fixture.so"
cc "$test_dir/archive.c" -L"$test_dir" \
  -Wl,-rpath,/usr/local/lib -Wl,--no-as-needed -lhutter-fixture \
  -o "$test_dir/entry/archive9"
chmod 0555 "$test_dir/entry/archive9"
printf 'install-provided runtime library\n' > "$test_dir/enwik9"

library_base64="$(base64 --wrap=0 "$test_dir/libhutter-fixture.so.1")"
{
  printf '%s\n' '#!/bin/sh' 'set -eu'
  printf "printf '%%s' '%s' | base64 --decode > /usr/local/lib/libhutter-fixture.so.1\n" \
    "$library_base64"
  printf '%s\n' \
    'ln -s libhutter-fixture.so.1 /usr/local/lib/libhutter-fixture.so' \
    'chmod 0444 /usr/local/lib/libhutter-fixture.so.1' \
    'mkdir -p /opt/hutter-runtime/bin' \
    'printf "hostile replacement\\n" > /opt/hutter-runtime/bin/exec-once' \
    'printf "hostile replacement\\n" > /usr/local/bin/run-archive' \
    'printf "#!/bin/sh\\nexit 99\\n" > /usr/sbin/ldconfig' \
    'chmod 0555 /usr/sbin/ldconfig'
} > "$test_dir/entry/install.sh"
chmod 0555 "$test_dir/entry/install.sh"

readonly base_image=hutter-prize-judging:dependency-runtime-test
docker build --tag "$base_image" "$project_dir" >/dev/null
source "$project_dir/lib/dependency-image.sh"
dependency_images="$(hp_dependency_image_build \
  "$project_dir" "$base_image" "$test_dir/entry" "$test_dir/dependencies")"
IFS=$'\t' read -r dependency_build_image dependency_runtime_image \
  <<< "$dependency_images"

docker image inspect "$dependency_build_image" >/dev/null
docker image inspect "$dependency_runtime_image" >/dev/null
common_worker_sha="$(docker run --rm "$base_image" \
  sha256sum /usr/local/bin/run-archive | awk '{print $1}')"
runtime_worker_sha="$(docker run --rm "$dependency_runtime_image" \
  sha256sum /usr/local/bin/run-archive | awk '{print $1}')"
[[ "$common_worker_sha" == "$runtime_worker_sha" ]]
docker run --rm "$dependency_runtime_image" \
  sh -c "ldd /opt/contestant-root/bin/exec-once 2>&1 | grep -q 'not a dynamic executable'"
docker run --rm "$dependency_runtime_image" \
  test -f /opt/contestant-root/usr/local/lib/libhutter-fixture.so.1

"$project_dir/qualify-archive.sh" \
  --skip-build \
  --image "$dependency_runtime_image" \
  --executable archive9 \
  --output data9 \
  --time-limit-seconds 30 \
  --expected-size "$(stat --format='%s' "$test_dir/enwik9")" \
  --memory-limit-bytes 134217728 \
  --disk-limit-bytes 104857600 \
  --disk-poll-seconds 1 \
  --work-root "$test_dir/work" \
  --results "$test_dir/results" \
  "$test_dir/entry" "$test_dir/enwik9"

summary="$(find "$test_dir/results" -name summary.tsv -type f -print -quit)"
grep -q $'^entry\tstatus\t' "$summary"
grep -q $'^entry\tPASS\t' "$summary"

echo "install-provided runtime library tests passed"
