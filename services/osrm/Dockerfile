# Pinned: osrm/osrm-backend:v5.25.0
FROM osrm/osrm-backend:v5.25.0@sha256:bdfa60e64ae1376bff6ff5605991be50600132a27469a4a9e77c23afd3a6d555

USER root

# Stretch is EOL — switch to archive repos before installing packages
RUN sed -i 's|deb.debian.org|archive.debian.org|g' /etc/apt/sources.list \
    && sed -i 's|security.debian.org|archive.debian.org|g' /etc/apt/sources.list \
    && sed -i '/stretch-updates/d' /etc/apt/sources.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates jq \
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

RUN id -u osrm >/dev/null 2>&1 || useradd -r -m osrm
RUN mkdir -p /var/osrm /osm && chown osrm:osrm /var/osrm /osm
USER osrm
EXPOSE 5000
ENTRYPOINT ["/entrypoint.sh"]
