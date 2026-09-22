#!/usr/bin/env bash

# Keep adversarial contestant material out of the judging-system repository.
# The one exception is the explicitly public, noncompetitive fixture.
hp_entry_location_require_external_or_fixture() {
  if (( $# != 2 )); then
    echo "error: hp_entry_location_require_external_or_fixture requires REPOSITORY_ROOT ENTRY_DIR" >&2
    return 2
  fi

  local repository_root entry_dir fixture_dir
  repository_root="$(realpath -- "$1")" || return 2
  entry_dir="$(realpath -- "$2")" || return 2
  fixture_dir="$repository_root/examples/well-formed-entry"

  if [[ "$entry_dir" == "$fixture_dir" ]]; then
    return 0
  fi
  if [[ "$entry_dir" == "$repository_root" \
      || "$entry_dir" == "$repository_root/"* ]]; then
    printf '%s\n' \
      "error: contestant entries must be stored outside the judging-system repository" \
      "       entry: $entry_dir" \
      "       repository: $repository_root" \
      "       only examples/well-formed-entry is permitted as an internal public fixture" >&2
    return 2
  fi
}
