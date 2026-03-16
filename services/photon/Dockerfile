# Pinned: eclipse-temurin:21-jre-alpine
FROM eclipse-temurin:21-jre-alpine@sha256:6ad8ed080d9be96b61438ec3ce99388e294af216ed57356000c06070e85c5d5d

RUN apk add --no-cache curl bash jq

ARG PHOTON_VERSION=1.0.1
ARG PHOTON_JAR_SHA256=4ef937f7f33fb89fef403f825edae14299240a0115df756f8fad67b3dc266437
RUN mkdir -p /photon/photon_data \
    && curl -fsSL -o /photon/photon.jar \
       "https://github.com/komoot/photon/releases/download/${PHOTON_VERSION}/photon-${PHOTON_VERSION}.jar" \
    && echo "${PHOTON_JAR_SHA256}  /photon/photon.jar" | sha256sum -c -

COPY entrypoint.sh /photon/entrypoint.sh
RUN chmod +x /photon/entrypoint.sh

RUN adduser -D -h /photon photon \
    && chown -R photon:photon /photon
USER photon

WORKDIR /photon
EXPOSE 2322
ENTRYPOINT ["/photon/entrypoint.sh"]
