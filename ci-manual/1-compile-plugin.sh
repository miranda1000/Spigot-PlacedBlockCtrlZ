#!/usr/bin/env bash
# Compiles PlacedBlockCtrlZ into target/PlacedBlockCtrlZ-1.0.0.jar, the jar the other
# ci-manual/ scripts deploy and test. Equivalent to the README's
# `mvn clean install -Dmaven.test.skip=true`, just run inside a disposable Maven container so you
# don't need Java/Maven installed locally.
# Use a disposable Maven cache so recently updated dependencies are fetched anew.
set -e

MAVEN_IMAGE="maven:3.8.3-openjdk-17"
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
PROJECT_ROOT="$(realpath "$SCRIPT_DIR/..")"

cd "$PROJECT_ROOT"

echo "==> Compiling PlacedBlockCtrlZ (mvn clean install -Dmaven.test.skip=true)"
docker run --rm -it \
    --network host \
    -v "$PROJECT_ROOT":/project \
    --tmpfs /root/.m2 \
    "$MAVEN_IMAGE" \
    mvn clean install -Dmaven.test.skip=true --file /project

JAR="$PROJECT_ROOT/target/PlacedBlockCtrlZ-1.0.0.jar"
if [ ! -f "$JAR" ]; then
    echo "[e] Expected $JAR but it wasn't produced; check the Maven output above." >&2
    exit 1
fi

echo "==> Built $JAR"
