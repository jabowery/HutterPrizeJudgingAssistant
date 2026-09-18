#!/usr/bin/env bash

# Trusted catalog of supported qualification userspaces.  entry.env and CLI
# values select an alias from this table; they are never used as registry
# references.  Keep every reference digest-pinned so an alias cannot change
# underneath a recorded run.

readonly HP_DEFAULT_QUALIFICATION_OS=ubuntu-22.04

hp_qualification_os_image() {
  case "$1" in
    ubuntu-20.04)
      printf '%s\n' \
        'ubuntu:20.04@sha256:8feb4d8ca5354def3d8fce243717141ce31e2c428701f6682bd2fafe15388214'
      ;;
    ubuntu-22.04)
      printf '%s\n' \
        'ubuntu:22.04@sha256:58b87898e82351c6cf9cf5b9f3c20257bb9e2dcf33af051e12ce532d7f94e3fe'
      ;;
    ubuntu-24.04)
      printf '%s\n' \
        'ubuntu:24.04@sha256:b3cc40b72b93588182b5410f723c7aaf142363311c2aa993d8a453ddcbb3ae15'
      ;;
    *)
      printf 'unsupported qualification OS: %s (supported: %s)\n' \
        "$1" 'ubuntu-20.04, ubuntu-22.04, ubuntu-24.04' >&2
      return 2
      ;;
  esac
}

hp_qualification_os_image_tag() {
  hp_qualification_os_image "$1" >/dev/null || return
  printf 'hutter-prize-judging:%s\n' "$1"
}

hp_qualification_os_build() {
  local qualification_os="$1" image="$2" context="$3"
  local qualification_os_image
  qualification_os_image="$(hp_qualification_os_image "$qualification_os")" \
    || return
  docker build \
    --build-arg "QUALIFICATION_OS=$qualification_os" \
    --build-arg "QUALIFICATION_OS_IMAGE=$qualification_os_image" \
    --tag "$image" "$context"
}

hp_qualification_os_verify_image() {
  local image="$1" qualification_os="$2"
  local expected_image actual_os actual_image
  expected_image="$(hp_qualification_os_image "$qualification_os")" || return
  actual_os="$(docker image inspect "$image" \
    --format '{{index .Config.Labels "org.hutterprize.qualification-os"}}')" \
    || return
  actual_image="$(docker image inspect "$image" \
    --format '{{index .Config.Labels "org.hutterprize.qualification-os-image"}}')" \
    || return
  if [[ "$actual_os" != "$qualification_os" || "$actual_image" != "$expected_image" ]]; then
    printf 'Docker image %s is not the catalog image for %s\n' \
      "$image" "$qualification_os" >&2
    printf '  image labels: qualification OS=%s, source=%s\n' \
      "${actual_os:-missing}" "${actual_image:-missing}" >&2
    printf '  expected source: %s\n' "$expected_image" >&2
    return 2
  fi
}
