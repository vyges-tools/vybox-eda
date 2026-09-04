#!/usr/bin/env bash
# Build a vybox-eda image target with versions from versions.lock.
#
# Usage:
#   scripts/build.sh [target] [image-tag]
#     target    rtl2gds-base | rtl2gds | full   (default: rtl2gds)
#     image-tag default: ghcr.io/vyges-tools/vybox-eda:<target>
#
# Reads versions.lock and passes each KEY=VALUE through as --build-arg, so the
# Dockerfile ARG defaults are overridden by the locked versions. Run on x86_64.
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="${1:-rtl2gds}"
TAG="${2:-ghcr.io/vyges-tools/vybox-eda:${TARGET}}"

BUILD_ARGS=()
while IFS= read -r line; do
  case "$line" in ''|\#*) continue ;; esac
  BUILD_ARGS+=(--build-arg "$line")
done < versions.lock

echo "Building target '${TARGET}' -> ${TAG}"
echo "Pins: ${BUILD_ARGS[*]}"

# Container engine: docker by default; set CONTAINER_ENGINE=podman to use podman.
ENGINE="${CONTAINER_ENGINE:-docker}"
[ "$ENGINE" = "docker" ] && export DOCKER_BUILDKIT=1

# OCI provenance labels. These three cannot live in the Dockerfile as constants —
# they go stale the moment anyone rebuilds — so they are filled here, from git and
# the clock, and a dirty tree is reported as such rather than passed off as the commit.
VCS_REF="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  VCS_REF="${VCS_REF}-dirty"
fi
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
IMAGE_VERSION="${IMAGE_VERSION:-$(git describe --tags --always --dirty 2>/dev/null || echo dev)}"

echo "Labels: version=${IMAGE_VERSION} revision=${VCS_REF} created=${BUILD_DATE}"

"${ENGINE}" build \
  --target "${TARGET}" \
  --tag "${TAG}" \
  "${BUILD_ARGS[@]}" \
  --build-arg "VCS_REF=${VCS_REF}" \
  --build-arg "BUILD_DATE=${BUILD_DATE}" \
  --build-arg "IMAGE_VERSION=${IMAGE_VERSION}" \
  --platform linux/amd64 \
  .

echo "Done. Smoke-test it with:  ${ENGINE} run --rm ${TAG}"
