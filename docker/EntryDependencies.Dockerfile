ARG BASE_IMAGE=hutter-prize-judge:local
FROM ${BASE_IMAGE}

COPY install.sh /opt/hutter-entry/install.sh

# This is deliberately the only entry-defined root/network execution phase.
RUN chmod 0555 /opt/hutter-entry/install.sh \
    && mkdir -p /work/run/tmp \
    && chmod 1777 /work/run/tmp \
    && /opt/hutter-entry/install.sh \
    && rm -f /opt/hutter-entry/install.sh \
    && rm -rf /work/run
