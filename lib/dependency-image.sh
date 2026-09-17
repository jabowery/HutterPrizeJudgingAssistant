#!/usr/bin/env bash

hp_dependency_image_names() {
  local hp_dep_entry_dir="$1"
  local hp_dep_entry_name hp_dep_install_hash hp_dep_safe_name
  hp_dep_entry_name="$(basename -- "$hp_dep_entry_dir")"
  hp_dep_install_hash="$(sha256sum -- "$hp_dep_entry_dir/install.sh" | awk '{print $1}')" \
    || return 1
  hp_dep_safe_name="$(printf '%s' "$hp_dep_entry_name" \
    | tr -c 'a-zA-Z0-9_.-' '-' | tr '[:upper:]' '[:lower:]')"
  printf 'hutter-prize-entry-%s:%s-build\t' \
    "$hp_dep_safe_name" "${hp_dep_install_hash:0:16}"
  printf 'hutter-prize-entry-%s:%s-runtime\n' \
    "$hp_dep_safe_name" "${hp_dep_install_hash:0:16}"
}

hp_dependency_image_build() {
  local hp_dep_orchestrator_dir="$1"
  local hp_dep_base_image="$2"
  local hp_dep_entry_dir="$3"
  local hp_dep_result_dir="$4"
  local hp_dep_build_image="${5:-}"
  local hp_dep_runtime_image="${6:-}"
  local hp_dep_image_names
  local hp_dep_entry_name hp_dep_install_hash hp_dep_install_attempts
  local hp_dep_install_exit hp_dep_retry_delay
  local hp_dep_max_install_attempts=3

  hp_dep_entry_name="$(basename -- "$hp_dep_entry_dir")"
  hp_dep_install_hash="$(sha256sum -- "$hp_dep_entry_dir/install.sh" | awk '{print $1}')" \
    || return 1
  if [[ -z "$hp_dep_build_image" || -z "$hp_dep_runtime_image" ]]; then
    hp_dep_image_names="$(hp_dependency_image_names "$hp_dep_entry_dir")" \
      || return 1
    IFS=$'\t' read -r hp_dep_build_image hp_dep_runtime_image \
      <<< "$hp_dep_image_names"
  fi

  mkdir -p -- "$hp_dep_result_dir" || return 1
  : > "$hp_dep_result_dir/install.log"
  echo "[$hp_dep_entry_name] building dependency images; install.sh is the only entry root/network phase" >&2
  hp_dep_install_attempts=0
  hp_dep_install_exit=1
  while (( hp_dep_install_attempts < hp_dep_max_install_attempts )); do
    ((hp_dep_install_attempts += 1))
    echo "[$hp_dep_entry_name] dependency-image attempt $hp_dep_install_attempts/$hp_dep_max_install_attempts" \
      | tee -a "$hp_dep_result_dir/install.log" >&2
    set +e
    docker build \
      --file "$hp_dep_orchestrator_dir/docker/EntryDependencies.Dockerfile" \
      --build-arg "BASE_IMAGE=$hp_dep_base_image" \
      --target entry-install \
      --tag "$hp_dep_build_image" \
      "$hp_dep_entry_dir" 2>&1 | tee -a "$hp_dep_result_dir/install.log" >&2
    hp_dep_install_exit="${PIPESTATUS[0]}"
    set -e
    if (( hp_dep_install_exit == 0 )); then
      set +e
      docker build \
        --file "$hp_dep_orchestrator_dir/docker/EntryDependencies.Dockerfile" \
        --build-arg "BASE_IMAGE=$hp_dep_base_image" \
        --tag "$hp_dep_runtime_image" \
        "$hp_dep_entry_dir" 2>&1 | tee -a "$hp_dep_result_dir/install.log" >&2
      hp_dep_install_exit="${PIPESTATUS[0]}"
      set -e
    fi
    (( hp_dep_install_exit != 0 )) || break
    if (( hp_dep_install_attempts < hp_dep_max_install_attempts )); then
      hp_dep_retry_delay="$((hp_dep_install_attempts * 20))"
      echo "[$hp_dep_entry_name] dependency image failed with status $hp_dep_install_exit; retrying in ${hp_dep_retry_delay}s" \
        | tee -a "$hp_dep_result_dir/install.log" >&2
      sleep "$hp_dep_retry_delay"
    fi
  done
  if (( hp_dep_install_exit != 0 )); then
    echo "error: install.sh dependency image failed with status $hp_dep_install_exit" >&2
    return 1
  fi

  {
    echo "entry=$hp_dep_entry_name"
    echo "install_sha256=$hp_dep_install_hash"
    echo "install_attempts=$hp_dep_install_attempts"
    echo "install_max_attempts=$hp_dep_max_install_attempts"
    echo "base_image=$hp_dep_base_image"
    echo "base_image_id=$(docker image inspect "$hp_dep_base_image" --format '{{.Id}}')"
    echo "dependency_build_image=$hp_dep_build_image"
    echo "dependency_build_image_id=$(docker image inspect "$hp_dep_build_image" --format '{{.Id}}')"
    echo "dependency_runtime_image=$hp_dep_runtime_image"
    echo "dependency_runtime_image_id=$(docker image inspect "$hp_dep_runtime_image" --format '{{.Id}}')"
    echo "runtime_library_snapshot=ldconfig-resolved"
  } > "$hp_dep_result_dir/dependency-image.env"

  printf '%s\t%s\n' "$hp_dep_build_image" "$hp_dep_runtime_image"
}
