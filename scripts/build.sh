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

"${ENGINE}" build \
  --target "${TARGET}" \
  --tag "${TAG}" \
  "${BUILD_ARGS[@]}" \
  --platform linux/amd64 \
  .

echo "Done. Smoke-test it with:  ${ENGINE} run --rm ${TAG}"
