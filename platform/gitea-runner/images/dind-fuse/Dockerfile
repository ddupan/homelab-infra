ARG DOCKER_VERSION=29.7.1
FROM docker:${DOCKER_VERSION}-dind

RUN apk add --no-cache fuse-overlayfs

COPY --chmod=0755 entrypoint.sh /usr/local/bin/dind-fuse-entrypoint

ENTRYPOINT ["/usr/local/bin/dind-fuse-entrypoint"]
CMD []
