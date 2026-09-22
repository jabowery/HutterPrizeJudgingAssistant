#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./scripts/check-repository-safety.sh
  ./scripts/check-repository-safety.sh --pre-push REMOTE_NAME

Reject tracked repository-local tmp/ content. In pre-push mode, read Git's
pre-push updates from standard input and inspect every newly published commit,
including commits in which tmp/ content was later deleted.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

mode=index
remote_name=""
case "${1:-}" in
  "") ;;
  --pre-push)
    [[ $# == 2 && -n "$2" ]] || { usage >&2; exit 2; }
    mode=pre-push
    remote_name="$2"
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" \
  || die "not inside a Git work tree"
cd -- "$repo_root"

git check-ignore -q --no-index tmp/confidential-entry \
  || die "the repository-root tmp/ directory is not ignored"

tracked_tmp="$(git ls-files -- tmp 'tmp/**')"
if [[ -n "$tracked_tmp" ]]; then
  printf '%s\n' \
    "error: repository-local tmp/ content is tracked or staged:" >&2
  while read -r tracked_path; do
    [[ -n "$tracked_path" ]] && printf '  %s\n' "$tracked_path" >&2
  done <<<"$tracked_tmp"
  exit 1
fi

[[ "$mode" == pre-push ]] || exit 0

while read -r local_ref local_oid remote_ref remote_oid; do
  [[ -n "${local_ref:-}" ]] || continue
  [[ ! "$local_oid" =~ ^0+$ ]] || continue

  if [[ "$remote_oid" =~ ^0+$ ]]; then
    commit_range=("$local_oid" --not --remotes="$remote_name")
  else
    commit_range=("$local_oid" "^$remote_oid")
  fi

  while read -r commit_oid; do
    [[ -n "$commit_oid" ]] || continue
    disclosed_paths="$(
      git ls-tree -r --name-only "$commit_oid" -- tmp 'tmp/**'
    )"
    if [[ -n "$disclosed_paths" ]]; then
      printf '%s\n' \
        "error: push rejected because outgoing commit $commit_oid contains repository-local tmp/ content:" >&2
      while read -r disclosed_path; do
        [[ -n "$disclosed_path" ]] \
          && printf '  %s\n' "$disclosed_path" >&2
      done <<<"$disclosed_paths"
      printf '%s\n' \
        "Remove the content from the commit history before pushing; deleting it in a later commit is insufficient." >&2
      exit 1
    fi
  done < <(git rev-list "${commit_range[@]}")
done
