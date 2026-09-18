#!/bin/sh
set -eu

# This diagnostic entry requires the coherent Ubuntu 24.04 userspace selected
# by QUALIFICATION_OS=ubuntu-24.04. Do not graft Noble's C library onto an
# older distribution: archive9 also depends on the matching C++ runtime.
. /etc/os-release
[ "$ID" = ubuntu ] && [ "$VERSION_ID" = 24.04 ] || {
  echo 'cmix-neif-pre2 requires QUALIFICATION_OS=ubuntu-24.04' >&2
  exit 2
}
