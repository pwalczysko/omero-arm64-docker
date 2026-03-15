# SPDX-License-Identifier: Apache-2.0
#
# omero-web.Dockerfile — ARM64-native OMERO.web image
#
# This file is part of omero-arm64-docker (https://github.com/simonhard/omero-arm64-docker)
# and is licensed under the Apache License, Version 2.0.
#
# The image built from this Dockerfile incorporates third-party software
# under different licenses. See THIRD_PARTY_NOTICES.md for details:
#   - OMERO.web      GPL-2.0       https://github.com/ome/openmicroscopy
#   - omero-web-docker  BSD-2-Clause  https://github.com/ome/omero-web-docker
#
# Build context: upstream omero-web-docker repo (cloned by build.py into _build/)
#   docker buildx build -f dockerfiles/omero-web.Dockerfile _build/omero-web-docker/

FROM rockylinux:9

LABEL maintainer="ome-devel@lists.openmicroscopy.org.uk"
LABEL org.opencontainers.image.source="https://github.com/simonhard/omero-arm64-docker"
LABEL org.opencontainers.image.licenses="Apache-2.0 AND GPL-2.0-only"
LABEL org.opencontainers.image.description="ARM64-native OMERO.web (Apple Silicon / aarch64)"

RUN mkdir /opt/setup
WORKDIR /opt/setup
ADD playbook.yml requirements.yml /opt/setup/

ENV LANG=en_US.utf-8

# Install all system prerequisites and set up Ansible in a single layer so
# that dnf caches are cleaned before the layer is committed.
RUN dnf -y install epel-release && \
    dnf install -y glibc-langpack-en ansible-core sudo && \
    ansible-galaxy collection install ansible.posix community.general && \
    ansible-galaxy install -p /opt/setup/roles -r requirements.yml && \
    dnf -y clean all && \
    rm -fr /var/cache

# Patch upstream roles for aarch64:
#  1. strip .x86_64 dnf arch suffix
#  2. swap the zeroc-ice GitHub repo from x86_64 to aarch64
#  3. update the wheel release date (20240202 -> 20240620)
#  4. swap the wheel platform tag (manylinux_2_28_x86_64 -> manylinux_2_28_aarch64)
RUN find /opt/setup/roles -name '*.yml' -exec \
      sed -i \
        -e 's/\.x86_64//g' \
        -e 's/zeroc-ice-py-linux-x86_64/zeroc-ice-py-linux-aarch64/g' \
        -e 's|download/20240202|download/20240620|g' \
        -e 's/manylinux_2_28_x86_64/manylinux_2_28_aarch64/g' \
      {} +

# Run Ansible provisioning and clean up in the same layer.
RUN ansible-playbook playbook.yml \
      -e 'ansible_python_interpreter=/usr/bin/python3' && \
    dnf -y clean all && \
    rm -fr /var/cache

# Install WhiteNoise and add middleware config so static files are served.
RUN /opt/omero/web/venv3/bin/pip install whitenoise && \
    echo 'config append -- omero.web.middleware '"'"'{"index": 0, "class": "whitenoise.middleware.WhiteNoiseMiddleware"}'"'"'' > /opt/omero/web/config/00-whitenoise.omero

# Install dumb-init for the correct architecture.
ARG TARGETARCH
RUN if [ "$TARGETARCH" = "arm64" ]; then ARCH=aarch64; else ARCH=x86_64; fi && \
    curl -L -o /usr/local/bin/dumb-init \
    "https://github.com/Yelp/dumb-init/releases/download/v1.2.5/dumb-init_1.2.5_${ARCH}" && \
    chmod +x /usr/local/bin/dumb-init

ADD entrypoint.sh /usr/local/bin/
ADD 50-config.py 60-default-web-config.sh 98-cleanprevious.sh 99-run.sh /startup/
ADD ice.config /opt/omero/web/OMERO.web/etc/

USER omero-web
EXPOSE 4080
VOLUME ["/opt/omero/web/OMERO.web/var"]

ENV OMERODIR=/opt/omero/web/OMERO.web/
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
