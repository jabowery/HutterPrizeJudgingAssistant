FROM ubuntu:22.04@sha256:58b87898e82351c6cf9cf5b9f3c20257bb9e2dcf33af051e12ce532d7f94e3fe AS launcher-build

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install --yes --no-install-recommends gcc libc6-dev \
    && rm -rf /var/lib/apt/lists/*
COPY docker/exec-once.c /src/exec-once.c
RUN gcc -O2 -Wall -Wextra -Werror /src/exec-once.c -o /exec-once

FROM ubuntu:22.04@sha256:58b87898e82351c6cf9cf5b9f3c20257bb9e2dcf33af051e12ce532d7f94e3fe

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
         ca-certificates curl libarchive-tools time util-linux \
    && rm -rf /var/lib/apt/lists/*

COPY docker/init-work /usr/local/bin/init-work
COPY docker/run-archive /usr/local/bin/run-archive
COPY docker/verify-output /usr/local/bin/verify-output
COPY docker/clean-work /usr/local/bin/clean-work
COPY docker/init-compression /usr/local/bin/init-compression
COPY docker/run-compressor /usr/local/bin/run-compressor
COPY docker/prepare-entry /usr/local/bin/prepare-entry
COPY docker/validate-executable /usr/local/bin/validate-executable
COPY --from=launcher-build /exec-once /usr/local/bin/exec-once

ADD Geekbench-5.5.1-Linux.tar.gz /opt/geekbench/
ADD UPX-5.1.1-amd64_linux.tar.xz /opt/upx/

RUN chmod 0555 \
      /usr/local/bin/init-work \
      /usr/local/bin/run-archive \
      /usr/local/bin/verify-output \
      /usr/local/bin/clean-work \
      /usr/local/bin/init-compression \
      /usr/local/bin/run-compressor \
      /usr/local/bin/prepare-entry \
      /usr/local/bin/validate-executable \
      /usr/local/bin/exec-once \
      /opt/upx/upx-5.1.1-amd64_linux/upx \
      /opt/geekbench/Geekbench-5.5.1-Linux/geekbench5 \
      /opt/geekbench/Geekbench-5.5.1-Linux/geekbench_x86_64 \
    && groupadd --gid 65532 contestant \
    && useradd --no-create-home --home-dir /nonexistent \
         --no-user-group --gid 65532 --uid 65532 contestant \
    && mkdir -p /reference /submission /work \
    && chmod 0555 /reference /submission \
    && mkdir -p \
         /opt/contestant-root/bin \
         /opt/contestant-root/lib/x86_64-linux-gnu \
         /opt/contestant-root/lib64 \
         /opt/contestant-root/dev \
         /opt/contestant-root/proc/self \
         /opt/contestant-root/usr/lib/x86_64-linux-gnu \
         /opt/contestant-root/work \
    && cp /usr/local/bin/exec-once /opt/contestant-root/bin/exec-once \
    && cp -L --parents \
         /bin/dash \
         /lib64/ld-linux-x86-64.so.2 \
         /lib/x86_64-linux-gnu/libc.so.6 \
         /lib/x86_64-linux-gnu/libm.so.6 \
         /lib/x86_64-linux-gnu/libpthread.so.0 \
         /lib/x86_64-linux-gnu/libdl.so.2 \
         /lib/x86_64-linux-gnu/librt.so.1 \
         /lib/x86_64-linux-gnu/libgcc_s.so.1 \
         /usr/lib/x86_64-linux-gnu/libstdc++.so.6 \
         --target-directory=/opt/contestant-root \
    && ln -s dash /opt/contestant-root/bin/sh \
    && ln -s work/run/tmp /opt/contestant-root/tmp \
    && touch /opt/contestant-root/dev/null \
    && chmod 0555 /opt/contestant-root /opt/contestant-root/work \
    && rm -rf /tmp \
    && ln -s /work/run/tmp /tmp

WORKDIR /work

CMD ["/usr/local/bin/run-archive"]
