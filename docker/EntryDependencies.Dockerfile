ARG BASE_IMAGE=hutter-prize-judging:local
FROM ${BASE_IMAGE} AS entry-install

COPY install.sh /opt/hutter-entry/install.sh

# This is deliberately the only entry-defined root/network execution phase.
RUN chmod 0555 /opt/hutter-entry/install.sh \
    && mkdir -p /work/run/tmp \
    && chmod 1777 /work/run/tmp \
    && /opt/hutter-entry/install.sh \
    && rm -f /opt/hutter-entry/install.sh \
    && rm -rf /work/run

# Copy candidate library trees into a fresh trusted stage. No program modified
# by install.sh participates in selecting or copying the runtime files.
FROM ${BASE_IMAGE} AS runtime-collector

RUN rm -rf /opt/installed-root /opt/hutter-runtime \
    && mkdir -p /opt/installed-root/etc /opt/hutter-runtime
COPY --from=entry-install /etc/ld.so.conf /opt/installed-root/etc/ld.so.conf
COPY --from=entry-install /etc/ld.so.conf.d/ /opt/installed-root/etc/ld.so.conf.d/
COPY --from=entry-install /lib/ /opt/installed-root/lib/
COPY --from=entry-install /lib64/ /opt/installed-root/lib64/
COPY --from=entry-install /usr/lib/ /opt/installed-root/usr/lib/
COPY --from=entry-install /usr/local/lib/ /opt/installed-root/usr/local/lib/

RUN set -eu; \
    copy_runtime_file() { \
      runtime_destination="$(realpath -sm -- "$1")"; \
      case "$runtime_destination" in \
        /lib/*|/lib64/*|/usr/lib/*|/usr/local/lib/*) ;; \
        *) echo "unsafe runtime library path: $1" >&2; exit 1 ;; \
      esac; \
      runtime_current="$runtime_destination"; \
      runtime_hops=0; \
      while :; do \
        runtime_current="$(realpath -sm -- "$runtime_current")"; \
        case "$runtime_current" in \
          /lib/*|/lib64/*|/usr/lib/*|/usr/local/lib/*) ;; \
          *) echo "runtime library escapes permitted directories: $1" >&2; exit 1 ;; \
        esac; \
        runtime_parent="$(dirname -- "$runtime_current")"; \
        while [ "$runtime_parent" != / ]; do \
          [ ! -L "/opt/installed-root$runtime_parent" ] \
            || { echo "runtime library has symlinked parent: $1" >&2; exit 1; }; \
          runtime_parent="$(dirname -- "$runtime_parent")"; \
        done; \
        runtime_source="/opt/installed-root$runtime_current"; \
        if [ ! -L "$runtime_source" ]; then break; fi; \
        runtime_target="$(readlink -- "$runtime_source")"; \
        case "$runtime_target" in \
          /*) runtime_current="$runtime_target" ;; \
          *) runtime_current="$(dirname -- "$runtime_current")/$runtime_target" ;; \
        esac; \
        runtime_hops="$((runtime_hops + 1))"; \
        [ "$runtime_hops" -le 40 ] \
          || { echo "too many runtime library symlinks: $1" >&2; exit 1; }; \
      done; \
      [ -f "$runtime_source" ] \
        || { echo "runtime library is not a file: $1" >&2; exit 1; }; \
      mkdir -p -- "/opt/hutter-runtime$(dirname -- "$runtime_destination")"; \
      cp -p -- "$runtime_source" "/opt/hutter-runtime$runtime_destination"; \
    }; \
    ldconfig -r /opt/installed-root; \
    ldconfig -r /opt/installed-root -p \
      | sed -n 's/.* => \(\/.*\)$/\1/p' \
      | LC_ALL=C sort -u > /opt/hutter-runtime-libraries; \
    while IFS= read -r runtime_path; do \
      copy_runtime_file "$runtime_path"; \
    done < /opt/hutter-runtime-libraries; \
    for loader in /lib64/ld-linux-x86-64.so.2 /lib/ld-linux.so.2; do \
      [ ! -e "/opt/installed-root$loader" ] \
        || copy_runtime_file "$loader"; \
    done; \
    mkdir -p /opt/hutter-runtime/etc; \
    cp -p -- /opt/installed-root/etc/ld.so.cache \
      /opt/hutter-runtime/etc/ld.so.cache; \
    rm -f /opt/hutter-runtime-libraries

FROM ${BASE_IMAGE}

COPY --from=runtime-collector /opt/hutter-runtime/ /opt/contestant-root/
