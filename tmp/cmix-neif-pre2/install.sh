#!/bin/sh
set -eu

# Runtime compatibility for Wolk/cmix-neif-pre2. Its archive9 extracts an
# embedded cmix image that requires GLIBC_2.38, while the common Ubuntu 22.04
# image supplies GLIBC_2.35. Ubuntu 24.04 LTS supplies a maintained, backward-
# compatible glibc with that symbol version.
export DEBIAN_FRONTEND=noninteractive

cat > /etc/apt/sources.list.d/cmix-neif-noble.sources <<'EOF'
Types: deb
URIs: http://archive.ubuntu.com/ubuntu
Suites: noble noble-updates
Components: main
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: http://security.ubuntu.com/ubuntu
Suites: noble-security
Components: main
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF

apt-get update -o Acquire::Retries=3
apt-get install --yes --no-install-recommends --target-release noble-updates \
  libc6 libc-bin libgcc-s1
ldconfig

rm -f /etc/apt/sources.list.d/cmix-neif-noble.sources
rm -rf /var/lib/apt/lists/*
