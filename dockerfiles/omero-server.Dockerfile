# SPDX-License-Identifier: Apache-2.0
#
# omero-server.Dockerfile — ARM64-native OMERO.server image
#
# This file is part of omero-arm64-docker (https://github.com/simonhard/omero-arm64-docker)
# and is licensed under the Apache License, Version 2.0.
#
# The image built from this Dockerfile incorporates third-party software
# under different licenses. See THIRD_PARTY_NOTICES.md for details:
#   - OMERO.server   GPL-2.0  https://github.com/ome/openmicroscopy
#   - ZeroC Ice 3.6  GPL-2.0  https://github.com/zeroc-ice/ice (tag v3.6.5)
#   - omero-server-docker  BSD-2-Clause  https://github.com/ome/omero-server-docker
#
# Build context: upstream omero-server-docker repo (cloned by build.py into _build/)
#   docker buildx build -f dockerfiles/omero-server.Dockerfile _build/omero-server-docker/

# ---------------------------------------------------------------------------
# Stage 1: compile Ice 3.6.5 C++ from source for the target architecture.
# Mirrors the Glencoe Software build at glencoesoftware/zeroc-ice-rhel9-x86_64
# but works on any arch (including aarch64) because there is no pre-built
# aarch64 tarball.
# ---------------------------------------------------------------------------
FROM rockylinux:9 AS ice-builder

RUN dnf -y install epel-release 'dnf-command(config-manager)' && \
    dnf config-manager --set-enabled crb && \
    dnf -y install \
      bzip2-devel expat-devel gcc gcc-c++ git \
      libdb-devel libdb-cxx-devel make openssl-devel && \
    dnf install -y https://zeroc.com/download/ice/3.7/el8/ice-repo-3.7.el8.noarch.rpm && \
    dnf install -y mcpp-devel && \
    dnf -y clean all && rm -rf /var/cache

RUN git clone --depth 1 --branch v3.6.5 https://github.com/zeroc-ice/ice.git /ice

# OpenSSL 3.0 compatibility patch (zeroc-ice/ice#1320)
RUN sed -i \
      -e 's/stackSize < PTHREAD_STACK_MIN/stackSize < static_cast<size_t>(PTHREAD_STACK_MIN)/g' \
      -e 's/stackSize = PTHREAD_STACK_MIN/stackSize = static_cast<size_t>(PTHREAD_STACK_MIN)/g' \
      /ice/cpp/src/IceUtil/Thread.cpp

RUN cd /ice/cpp && \
    CPPFLAGS='-Wno-error=deprecated-declarations -Wno-error=unused-result -Wno-error=register' \
    make -j$(nproc) install

# ---------------------------------------------------------------------------
# Stage 2: OMERO server image
# ---------------------------------------------------------------------------
FROM rockylinux:9

LABEL maintainer="ome-devel@lists.openmicroscopy.org.uk"
LABEL org.opencontainers.image.source="https://github.com/simonhard/omero-arm64-docker"
LABEL org.opencontainers.image.licenses="Apache-2.0 AND GPL-2.0-only"
LABEL org.opencontainers.image.description="ARM64-native OMERO.server (Apple Silicon / aarch64)"

ENV LANG=en_US.utf-8
ENV RHEL_FRONTEND=noninteractive

# Copy the aarch64 Ice binaries built in stage 1.
# /opt/ice symlink is what OMERO and the ome.ice role expect.
COPY --from=ice-builder /opt/Ice-3.6.5 /opt/Ice-3.6.5
RUN ln -s /opt/Ice-3.6.5 /opt/ice

RUN mkdir /opt/setup
WORKDIR /opt/setup
ADD playbook.yml requirements.yml /opt/setup/

# Install all system prerequisites and set up Ansible in a single layer so
# that dnf caches are cleaned before the layer is committed.
RUN dnf -y install epel-release && \
    dnf -y update && \
    dnf install -y glibc-langpack-en blosc ansible-core sudo ca-certificates && \
    ansible-galaxy install -p /opt/setup/roles -r requirements.yml && \
    dnf -y clean all && \
    rm -fr /var/cache

ARG OMERO_VERSION=5.6.17
ARG OMEGO_ADDITIONAL_ARGS=
ENV OMERODIR=/opt/omero/server/OMERO.server

# Patch upstream roles for aarch64:
#  1. strip .x86_64 dnf arch suffix (e.g. python3.11-devel.x86_64)
#  2. swap the zeroc-ice GitHub repo from x86_64 to aarch64
#  3. update the wheel release date (20240202 -> 20240620)
#  4. swap the wheel platform tag (manylinux_2_28_x86_64 -> manylinux_2_28_aarch64)
# Additionally, neutralise the ome.deploy_archive role so the ome.ice role
# does not attempt to download the x86_64 Ice tarball -- the binaries were
# already copied from the ice-builder stage above.
RUN find /opt/setup/roles -name '*.yml' -exec \
      sed -i \
        -e 's/\.x86_64//g' \
        -e 's/zeroc-ice-py-linux-x86_64/zeroc-ice-py-linux-aarch64/g' \
        -e 's|download/20240202|download/20240620|g' \
        -e 's/manylinux_2_28_x86_64/manylinux_2_28_aarch64/g' \
      {} + && \
    echo '---' > /opt/setup/roles/ome.deploy_archive/tasks/main.yml

# Run Ansible provisioning and clean up in the same layer.
# Fix /etc/shadow permissions so PAM/sudo works in buildx (e.g. GitHub Actions).
RUN chmod 0400 /etc/shadow 2>/dev/null || true && \
    TMPDIR=/var/tmp ansible-playbook playbook.yml -vvv \
      -e 'ansible_python_interpreter=/usr/bin/python3' \
      -e omero_server_release=$OMERO_VERSION \
      -e omero_server_omego_additional_args="$OMEGO_ADDITIONAL_ARGS" && \
    dnf -y clean all && \
    rm -fr /var/cache /tmp/* /var/tmp/ansible-*

# Install dumb-init for the correct architecture.
ARG TARGETARCH
RUN if [ "$TARGETARCH" = "arm64" ]; then ARCH=aarch64; else ARCH=x86_64; fi && \
    curl -L -o /usr/local/bin/dumb-init \
    "https://github.com/Yelp/dumb-init/releases/download/v1.2.5/dumb-init_1.2.5_${ARCH}" && \
    chmod +x /usr/local/bin/dumb-init

ADD entrypoint.sh /usr/local/bin/
ADD 50-config.py 60-database.sh 99-run.sh /startup/

# Move certificates generation to a separate script so it runs after 50-config.py
# applies CONFIG_ env vars (e.g. omero.certificates.commonname).
RUN sed -i '/^certificates/d' /opt/omero/server/config/00-omero-server.omero && \
    printf '#!/bin/bash\nset -eu\n/opt/omero/server/venv3/bin/omero certificates -v\n' > /startup/51-certificates.sh && \
    chmod +x /startup/51-certificates.sh

USER omero-server
EXPOSE 4063 4064
ENV PATH=$PATH:/opt/ice/bin

VOLUME ["/OMERO", "/opt/omero/server/OMERO.server/var"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
