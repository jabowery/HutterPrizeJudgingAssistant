#!/usr/bin/env bash

# Retry idempotent uploads because a newly booted Compute Engine SSH service
# can transiently reset a second connection during key exchange. A retry may
# overwrite a partial remote file; the caller must verify its digest afterward.
hp_gcloud_scp_with_retry() {
  if (( $# != 5 )); then
    echo "error: hp_gcloud_scp_with_retry requires INSTANCE PROJECT ZONE SOURCE DESTINATION" >&2
    return 2
  fi

  local instance="$1" project="$2" zone="$3" source_path="$4" remote_path="$5"
  local attempt status
  local -r maximum_attempts=5

  for ((attempt = 1; attempt <= maximum_attempts; attempt++)); do
    if gcloud compute scp \
        --project="$project" --zone="$zone" --quiet \
        "$source_path" "$instance:$remote_path"; then
      return 0
    else
      status=$?
    fi

    if (( attempt == maximum_attempts )); then
      echo "error: cloud upload failed after $maximum_attempts attempts" >&2
      return "$status"
    fi
    echo "Cloud upload attempt $attempt/$maximum_attempts failed; retrying after $((attempt * 5)) seconds..." >&2
    sleep "$((attempt * 5))"
  done
}
