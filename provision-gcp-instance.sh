#!/usr/bin/env bash
set -Eeuo pipefail

instance_name=hutter-judging-node
project=""
machine_type=t2d-standard-4
region=us-central1
boot_disk_size=200GB
boot_disk_type=pd-ssd
image_family=ubuntu-2404-lts-amd64
image_project=ubuntu-os-cloud
network=""
subnet=""
tags=""
labels=purpose=hutter-prize-judging
declare -a requested_zones=()

usage() {
  cat <<'EOF'
Usage: ./provision-gcp-instance.sh [OPTIONS]

Create a credential-free, Shielded Google Compute Engine instance suitable for
the judging system. Candidate zones are tried in order until creation succeeds.
The selected zone is the only value written to stdout; progress goes to stderr.

Options:
  --name NAME                 Default: hutter-judging-node
  --project PROJECT           Default: active gcloud project
  --machine-type TYPE         Default: t2d-standard-4 (16 GiB)
  --region REGION             Discover candidate zones here (default: us-central1)
  --zone ZONE                 Candidate zone; repeat to set an explicit order
  --boot-disk-size SIZE       Default: 200GB
  --boot-disk-type TYPE       Default: pd-ssd
  --image-family FAMILY       Default: ubuntu-2404-lts-amd64
  --image-project PROJECT     Default: ubuntu-os-cloud
  --network NETWORK           Optional VPC network
  --subnet SUBNET             Optional VPC subnet
  --tags TAGS                 Optional comma-separated network tags
  --labels LABELS             Default: purpose=hutter-prize-judging
  -h, --help                  Show this help

Local gcloud authentication is inherited from the invoking environment. It is
never copied to the instance. The instance is always created with no attached
service account and no OAuth scopes; those security properties are not
overridable.
EOF
}

die() {
  echo "error: $*" >&2
  exit 2
}

usage_error() {
  echo "error: $*" >&2
  echo >&2
  usage >&2
  exit 2
}

while (( $# > 0 )); do
  case "$1" in
    --name) (( $# >= 2 )) || usage_error "$1 requires a value"; instance_name="$2"; shift 2 ;;
    --project) (( $# >= 2 )) || usage_error "$1 requires a value"; project="$2"; shift 2 ;;
    --machine-type) (( $# >= 2 )) || usage_error "$1 requires a value"; machine_type="$2"; shift 2 ;;
    --region) (( $# >= 2 )) || usage_error "$1 requires a value"; region="$2"; shift 2 ;;
    --zone) (( $# >= 2 )) || usage_error "$1 requires a value"; requested_zones+=("$2"); shift 2 ;;
    --boot-disk-size) (( $# >= 2 )) || usage_error "$1 requires a value"; boot_disk_size="$2"; shift 2 ;;
    --boot-disk-type) (( $# >= 2 )) || usage_error "$1 requires a value"; boot_disk_type="$2"; shift 2 ;;
    --image-family) (( $# >= 2 )) || usage_error "$1 requires a value"; image_family="$2"; shift 2 ;;
    --image-project) (( $# >= 2 )) || usage_error "$1 requires a value"; image_project="$2"; shift 2 ;;
    --network) (( $# >= 2 )) || usage_error "$1 requires a value"; network="$2"; shift 2 ;;
    --subnet) (( $# >= 2 )) || usage_error "$1 requires a value"; subnet="$2"; shift 2 ;;
    --tags) (( $# >= 2 )) || usage_error "$1 requires a value"; tags="$2"; shift 2 ;;
    --labels) (( $# >= 2 )) || usage_error "$1 requires a value"; labels="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage_error "unknown option: $1" ;;
  esac
done

command -v gcloud >/dev/null 2>&1 || die "gcloud is not installed or is not in PATH"
[[ "$instance_name" =~ ^[a-z]([-a-z0-9]{0,61}[a-z0-9])?$ ]] \
  || usage_error "name must be a valid Compute Engine instance name"
[[ -n "$machine_type" && -n "$region" && -n "$boot_disk_type" \
    && -n "$image_family" && -n "$image_project" ]] \
  || usage_error "machine, region, disk, and image values must not be empty"
[[ "$boot_disk_size" =~ ^[1-9][0-9]*(GB|TB)$ ]] \
  || usage_error "boot-disk-size must be a whole number of GB or TB"

if [[ -z "$project" ]]; then
  project="$(gcloud config get-value project 2>/dev/null)" \
    || die "could not read the active gcloud project"
fi
[[ -n "$project" && "$project" != '(unset)' ]] \
  || die "no Google Cloud project is selected; use --project"
readonly -a project_args=(--project="$project")

existing_zone="$(gcloud compute instances list "${project_args[@]}" \
  --filter="name=$instance_name" --format='value(zone)' 2>/dev/null)" \
  || die "could not check for an existing instance"
if [[ -n "$existing_zone" ]]; then
  existing_zone="${existing_zone##*/}"
  die "instance $instance_name already exists in $existing_zone"
fi

declare -a candidate_zones=()
if (( ${#requested_zones[@]} > 0 )); then
  candidate_zones=("${requested_zones[@]}")
else
  zone_output="$(gcloud compute machine-types list "${project_args[@]}" \
    --filter="name=$machine_type AND zone~$region" \
    --format='value(zone)')" \
    || die "could not discover zones containing machine type $machine_type"
  while IFS= read -r zone; do
    zone="${zone##*/}"
    [[ "$zone" == "$region-"* ]] && candidate_zones+=("$zone")
  done <<< "$zone_output"
fi
(( ${#candidate_zones[@]} > 0 )) \
  || die "no candidate zones found for $machine_type in $region"

declare -A attempted_zones=()
for zone in "${candidate_zones[@]}"; do
  [[ "$zone" =~ ^[a-z0-9-]+$ ]] || die "invalid zone: $zone"
  [[ -z "${attempted_zones[$zone]+x}" ]] || continue
  attempted_zones[$zone]=1

  memory_mb="$(gcloud compute machine-types describe "$machine_type" \
    "${project_args[@]}" --zone="$zone" --format='value(memoryMb)' 2>/dev/null)" \
    || { echo "Skipping $zone: cannot describe $machine_type." >&2; continue; }
  if [[ ! "$memory_mb" =~ ^[0-9]+$ || "$memory_mb" -lt 16384 ]]; then
    echo "Skipping $zone: $machine_type provides ${memory_mb:-unknown} MiB; at least 16384 MiB is required." >&2
    continue
  fi

  echo "Attempting creation of $instance_name in $zone..." >&2
  create_args=(
    gcloud compute instances create "$instance_name"
    "${project_args[@]}"
    --zone="$zone"
    --machine-type="$machine_type"
    --boot-disk-size="$boot_disk_size"
    --boot-disk-type="$boot_disk_type"
    --image-family="$image_family"
    --image-project="$image_project"
    --provisioning-model=STANDARD
    --maintenance-policy=MIGRATE
    --no-service-account
    --no-scopes
    --metadata=block-project-ssh-keys=TRUE,serial-port-enable=FALSE
    --shielded-secure-boot
    --shielded-vtpm
    --shielded-integrity-monitoring
    --quiet
  )
  [[ -z "$network" ]] || create_args+=(--network="$network")
  [[ -z "$subnet" ]] || create_args+=(--subnet="$subnet")
  [[ -z "$tags" ]] || create_args+=(--tags="$tags")
  [[ -z "$labels" ]] || create_args+=(--labels="$labels")

  if "${create_args[@]}" >&2; then
    service_accounts="$(gcloud compute instances describe "$instance_name" \
      "${project_args[@]}" --zone="$zone" \
      --format='value(serviceAccounts.email)')" || {
        echo "error: created instance but could not verify its identity configuration" >&2
        echo "The instance was retained in $zone for inspection or explicit deletion." >&2
        printf 'Delete it with: gcloud compute instances delete %q --zone=%q --project=%q\n' \
          "$instance_name" "$zone" "$project" >&2
        exit 2
      }
    if [[ -n "$service_accounts" ]]; then
      echo "error: created instance unexpectedly has an attached service account; do not run entrant code" >&2
      echo "The instance was retained in $zone for inspection or explicit deletion." >&2
      printf 'Delete it with: gcloud compute instances delete %q --zone=%q --project=%q\n' \
        "$instance_name" "$zone" "$project" >&2
      exit 2
    fi
    echo "Successfully provisioned $instance_name in $zone without an attached service account." >&2
    printf '%s\n' "$zone"
    exit 0
  fi
  echo "Creation failed in $zone; trying the next candidate." >&2
done

die "could not provision $instance_name in any candidate zone"
