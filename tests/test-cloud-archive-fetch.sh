#!/usr/bin/env bash
set -Eeuo pipefail

readonly project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

mkdir -p -- "$test_root/bin"
cat > "$test_root/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
output=""
while (( $# > 0 )); do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$output" ]] || exit 90
printf 'submitted archive bytes\n' > "$output"
EOF
chmod 0500 -- "$test_root/bin/curl"

expected_sha256="$(printf 'submitted archive bytes\n' | sha256sum | awk '{print $1}')"
output="$test_root/archive9"
actual_sha256="$(PATH="$test_root/bin:$PATH" \
  "$project_dir/cloud/fetch-entry-archive.sh" \
    https://downloads.example.invalid/archive9 "$output" "$expected_sha256")"
[[ "$actual_sha256" == "$expected_sha256" ]] \
  || fail "fetch helper did not report the downloaded digest"
[[ "$(< "$output")" == 'submitted archive bytes' ]] \
  || fail "fetch helper did not install the downloaded archive"

if PATH="$test_root/bin:$PATH" "$project_dir/cloud/fetch-entry-archive.sh" \
    https://downloads.example.invalid/archive9 "$test_root/wrong" \
    0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
    >/dev/null 2>&1; then
  fail "fetch helper accepted a mismatched pinned digest"
fi
[[ ! -e "$test_root/wrong" ]] \
  || fail "fetch helper retained an archive after a digest mismatch"

echo "cloud archive fetch tests passed"
