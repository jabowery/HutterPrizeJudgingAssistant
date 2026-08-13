#!/usr/bin/env bash
set -Eeuo pipefail

readonly project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
violations=""

while IFS= read -r occurrence; do
  lowercase="${occurrence,,}"
  case "$lowercase" in
    *judge.sh*|*"human judge"*|*"human hutter prize official"*) ;;
    *) violations+="$occurrence"$'\n' ;;
  esac
done < <(
  git -C "$project_dir" grep -nI -i 'judge' -- . \
    ':(exclude)Entries/**' \
    ':(exclude)tests/test-terminology.sh' || true
)

if [[ -n "$violations" ]]; then
  echo "error: software described as a judge; reserve that term for a human official:" >&2
  printf '%s' "$violations" >&2
  exit 1
fi

echo "documentation terminology test passed"
