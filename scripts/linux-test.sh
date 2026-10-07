#!/usr/bin/env bash
# Runs the platform-independent core tests inside the official Swift Docker image.
# Usage: scripts/linux-test.sh [swift test args...]
set -euo pipefail
cd "$(dirname "$0")/.."
IMAGE="${SWIFT_IMAGE:-mirror.gcr.io/library/swift:6.1-noble}"
ENV_ARGS=()
for v in HTTPS_PROXY https_proxy HTTP_PROXY http_proxy; do
  [ -n "${!v:-}" ] && ENV_ARGS+=(-e "$v=${!v}")
done
CA_ARGS=()
if [ -f /root/.ccr/ca-bundle.crt ]; then
  CA_ARGS=(-v /root/.ccr/ca-bundle.crt:/ca.crt:ro -e GIT_SSL_CAINFO=/ca.crt -e SSL_CERT_FILE=/ca.crt)
fi
exec docker run --rm --network host "${ENV_ARGS[@]}" "${CA_ARGS[@]}" \
  -v "$PWD":/work -w /work "$IMAGE" \
  bash -c 'swift test --scratch-path /work/.build/linux "$@"' _ "$@"
