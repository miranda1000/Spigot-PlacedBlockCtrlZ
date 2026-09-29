#!/usr/bin/env bash
# Optional convenience: stops the container ci-manual/2-start-server.sh started. Not one of the
# 4 requested scripts, but --rm means the container (and this script) is the only way to reclaim
# the port once you're done testing.
set -e

CONTAINER_NAME="${CONTAINER_NAME:-watchwolf-manual-server}"

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    echo "==> $CONTAINER_NAME isn't running."
    exit 0
fi

echo "==> Stopping $CONTAINER_NAME"
docker stop "$CONTAINER_NAME" > /dev/null
echo "==> Stopped (it was started with --rm, so it's already gone)"
