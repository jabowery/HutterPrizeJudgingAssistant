#!/usr/bin/env bash
set -Eeuo pipefail
readonly project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
source "$project_dir/lib/assets.sh"
[[ "$(hp_asset_catalog Geekbench-5.5.1-Linux.tar.gz)" == \
  $'32037e55c3dc8f360fe16b7fbb188d31387ea75980e48d8cf028330e3239c404\t93199992\thttps://cdn.geekbench.com/Geekbench-5.5.1-Linux.tar.gz' ]]
[[ "$(hp_asset_catalog UPX-5.1.1-amd64_linux.tar.xz)" == *https://github.com/upx/upx/releases/download/v5.1.1/upx-5.1.1-amd64_linux.tar.xz ]]
! hp_asset_catalog entrant-script >/dev/null 2>&1 || fail 'unknown asset accepted'

mkdir -p "$test_root/bin" "$test_root/one" "$test_root/two" "$test_root/three"
printf 'trusted pinned asset fixture\n' > "$test_root/payload"
export TEST_ASSET_PAYLOAD="$test_root/payload"
export TEST_ASSET_SHA="$(sha256sum "$TEST_ASSET_PAYLOAD" | awk '{print $1}')"
export TEST_ASSET_SIZE="$(stat -c %s "$TEST_ASSET_PAYLOAD")"
export TEST_CURL_LOG="$test_root/curl.log" TEST_GIT_LOG="$test_root/git.log"
export HP_ASSET_CACHE_DIR="$test_root/cache"
cat > "$test_root/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$TEST_CURL_LOG"
output=
while (( $# )); do
  case "$1" in --output) output="$2"; shift 2 ;; *) shift ;; esac
done
sleep 0.1
cp "$TEST_ASSET_PAYLOAD" "$output"
EOF
cat > "$test_root/bin/git" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$TEST_GIT_LOG"
repo="$2"; shift 2
case "$*" in
  'rev-parse --git-path lfs/objects') printf '.git/lfs/objects\n' ;;
  'lfs fetch '* )
    [[ " $* " == *' --exclude= '* ]] || exit 91
    dest="$repo/.git/lfs/objects/${TEST_ASSET_SHA:0:2}/${TEST_ASSET_SHA:2:2}/$TEST_ASSET_SHA"
    mkdir -p "${dest%/*}"
    cp "$TEST_ASSET_PAYLOAD" "$dest"
    ;;
  *) exit 92 ;;
esac
EOF
chmod +x "$test_root/bin/curl" "$test_root/bin/git"
export PATH="$test_root/bin:$PATH"
# Only test fixtures replace the trusted catalog; operator/entrant data cannot.
hp_asset_catalog() {
  local url=https://publisher.example/tool
  [[ "$1" != examples/* ]] || url=lfs
  printf '%s\t%s\t%s\n' "$TEST_ASSET_SHA" "$TEST_ASSET_SIZE" "$url"
}
pointer() { printf 'version https://git-lfs.github.com/spec/v1\noid sha256:%s\nsize %s\n' "$TEST_ASSET_SHA" "$TEST_ASSET_SIZE" > "$1"; }

# Existing bytes seed a shared cache, including for a second independent clone.
cp "$TEST_ASSET_PAYLOAD" "$test_root/one/tool"
hp_asset_ensure "$test_root/one" tool
pointer "$test_root/two/tool"
hp_asset_ensure "$test_root/two" tool
cmp "$TEST_ASSET_PAYLOAD" "$test_root/two/tool"
[[ ! -e "$TEST_CURL_LOG" ]] || fail 'cached/local asset downloaded'
[[ ! -e "$TEST_GIT_LOG" ]] || fail 'cached/local asset used Git LFS'

# Concurrent cold misses have one publisher transfer, never an LFS transfer.
export HP_ASSET_CACHE_DIR="$test_root/concurrent-cache"
pointer "$test_root/one/tool"
pointer "$test_root/two/tool"
hp_asset_ensure "$test_root/one" tool & first=$!
hp_asset_ensure "$test_root/two" tool & second=$!
wait "$first"; wait "$second"
[[ "$(wc -l < "$TEST_CURL_LOG")" == 1 ]] || fail 'concurrent download was not shared'
! rg -q 'lfs fetch' "$TEST_GIT_LOG" || fail 'tool fell back to LFS'

# A corrupted cache is verified and repaired, rather than used as executable input.
chmod u+w "$HP_ASSET_CACHE_DIR/$TEST_ASSET_SHA"
printf 'bad cached data\n' > "$HP_ASSET_CACHE_DIR/$TEST_ASSET_SHA"
pointer "$test_root/three/tool"
hp_asset_ensure "$test_root/three" tool
cmp "$TEST_ASSET_PAYLOAD" "$test_root/three/tool"
[[ "$(wc -l < "$TEST_CURL_LOG")" == 2 ]] || fail 'bad cache was not refetched'
printf 'valuable local modification\n' > "$test_root/three/tool"
! hp_asset_ensure "$test_root/three" tool >/dev/null 2>&1 || fail 'bad local file accepted'
grep -qx 'valuable local modification' "$test_root/three/tool" || fail 'local file overwritten'

# Previously downloaded Git LFS objects seed new worktrees without an API call.
export HP_ASSET_CACHE_DIR="$test_root/lfs-seed-cache"
seed_object="$test_root/lfs-seed/.git/lfs/objects/${TEST_ASSET_SHA:0:2}/${TEST_ASSET_SHA:2:2}/$TEST_ASSET_SHA"
mkdir -p "${seed_object%/*}"
cp "$TEST_ASSET_PAYLOAD" "$seed_object"
pointer "$test_root/lfs-seed/tool"
hp_asset_ensure "$test_root/lfs-seed" tool
cmp "$TEST_ASSET_PAYLOAD" "$test_root/lfs-seed/tool"
[[ "$(wc -l < "$TEST_CURL_LOG")" == 2 ]] || fail 'local LFS object downloaded again'
! rg -q 'lfs fetch' "$TEST_GIT_LOG" || fail 'local object used remote LFS'

# Failed checksum validation never publishes either a cache object or a tool.
export HP_ASSET_CACHE_DIR="$test_root/bad-download-cache"
printf 'corrupt download\n' > "$test_root/bad-payload"
pointer "$test_root/three/tool"
TEST_ASSET_PAYLOAD="$test_root/bad-payload" \
  hp_asset_ensure "$test_root/three" tool >/dev/null 2>&1 && fail 'bad publisher bytes accepted'
[[ ! -e "$HP_ASSET_CACHE_DIR/$TEST_ASSET_SHA" ]] || fail 'bad object published'
grep -q '^version https://git-lfs' "$test_root/three/tool" || fail 'pointer replaced by bad bytes'
[[ -z "$(find "$HP_ASSET_CACHE_DIR" -name '.asset.*' -print)" ]] || fail 'failed transfer leaked temporary files'

# A cache symlink cannot redirect a privileged write to another file.
export HP_ASSET_CACHE_DIR="$test_root/symlink-cache"
mkdir -p "$HP_ASSET_CACHE_DIR"
ln -s "$TEST_ASSET_PAYLOAD" "$HP_ASSET_CACHE_DIR/$TEST_ASSET_SHA"
! hp_asset_ensure "$test_root/three" tool >/dev/null 2>&1 || fail 'symlink cache object accepted'

# The public example is fetched explicitly once, not by a general LFS pull.
export HP_ASSET_CACHE_DIR="$test_root/example-cache"
mkdir -p "$test_root/three/examples/well-formed-entry"
pointer "$test_root/three/examples/well-formed-entry/archive9"
hp_asset_ensure "$test_root/three" examples/well-formed-entry/archive9
[[ "$(stat -c %a "$test_root/three/examples/well-formed-entry/archive9")" == 555 ]]
[[ "$(rg -c 'lfs fetch' "$TEST_GIT_LOG")" == 1 ]] || fail 'example transfer not narrowly scoped'

# Every ordinary common-image build passes through the same asset check.
cat > "$test_root/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -eu
[[ "$1" == build ]] || exit 93
context="${@: -1}"
cmp "$TEST_ASSET_PAYLOAD" "$context/Geekbench-5.5.1-Linux.tar.gz"
cmp "$TEST_ASSET_PAYLOAD" "$context/UPX-5.1.1-amd64_linux.tar.xz"
EOF
chmod +x "$test_root/bin/docker"
source "$project_dir/lib/qualification-os.sh"
mkdir -p "$test_root/context"
hp_qualification_os_build ubuntu-22.04 test-image "$test_root/context"

# The committed LFS defaults prevent normal cloning from downloading all six
# objects before any judging script has a chance to select/cache them.
real_git="$(PATH="${PATH#*:}" command -v git)"
mkdir -p "$test_root/source-repo"
"$real_git" -C "$test_root/source-repo" init -q
"$real_git" -C "$test_root/source-repo" config user.name 'Asset Cache Test'
"$real_git" -C "$test_root/source-repo" config user.email asset-test@example.invalid
cp "$project_dir/.lfsconfig" "$test_root/source-repo/.lfsconfig"
printf 'large.bin filter=lfs diff=lfs merge=lfs -text\n' > "$test_root/source-repo/.gitattributes"
pointer "$test_root/source-repo/large.bin"
"$real_git" -C "$test_root/source-repo" add .
"$real_git" -C "$test_root/source-repo" -c core.hooksPath=/dev/null commit -qm fixture
PATH="${PATH#*:}" "$real_git" -c filter.lfs.process='git-lfs filter-process' -c filter.lfs.required=true \
  clone --quiet --no-local "$test_root/source-repo" "$test_root/new-clone"
grep -q '^version https://git-lfs' "$test_root/new-clone/large.bin" || fail 'clone did not defer LFS objects'
echo 'asset cache tests passed'
