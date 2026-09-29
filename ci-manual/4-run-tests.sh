#!/usr/bin/env bash
# Runs the integration tests (PlacedBlockCtrlZShould, via ManualServerTest) against the server
# started by ci-manual/2-start-server.sh and the ClientsManager started by
# ci-manual/3-start-clients-manager.sh. Structured the same way as MineIt's ci/run-tests.sh:
# Maven runs inside a disposable container, on the host network, so plain `mvn test` reaches
# 127.0.0.1 on the host.
# Use a disposable Maven cache so recently updated dependencies are fetched anew.
#
# Usage (same convention as MineIt):
#   ci-manual/4-run-tests.sh                        # every test
#   ci-manual/4-run-tests.sh PlacedBlockCtrlZShould  # one test class
#   ci-manual/4-run-tests.sh 'PlacedBlockCtrlZShould#placeAndUndoABlock'  # one test method
set -e

MAVEN_IMAGE="maven:3.8.3-openjdk-17"
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
PROJECT_ROOT="$(realpath "$SCRIPT_DIR/..")"

# Where ManualServerTest should reach the manually-started server and ClientsManager. Defaults
# match ci-manual/2-start-server.sh and ci-manual/3-start-clients-manager.sh; only override these
# if you started them differently. See ManualServerTest's Javadoc for the full list.
WATCHWOLF_SERVER_HOST="${WATCHWOLF_SERVER_HOST:-127.0.0.1}"
WATCHWOLF_SERVER_PORT="${WATCHWOLF_SERVER_PORT:-25565}"
WATCHWOLF_CLIENTSMANAGER_HOST="${WATCHWOLF_CLIENTSMANAGER_HOST:-$WATCHWOLF_SERVER_HOST}"
WATCHWOLF_CLIENTSMANAGER_PORT="${WATCHWOLF_CLIENTSMANAGER_PORT:-7000}"

cd "$PROJECT_ROOT"

run_maven() {
    docker run --rm -it \
        --network host \
        -v "$PROJECT_ROOT":/project \
        --tmpfs /root/.m2 \
        --env WATCHWOLF_SERVER_HOST="$WATCHWOLF_SERVER_HOST" \
        --env WATCHWOLF_SERVER_PORT="$WATCHWOLF_SERVER_PORT" \
        --env WATCHWOLF_CLIENTSMANAGER_HOST="$WATCHWOLF_CLIENTSMANAGER_HOST" \
        --env WATCHWOLF_CLIENTSMANAGER_PORT="$WATCHWOLF_CLIENTSMANAGER_PORT" \
        "$MAVEN_IMAGE" \
        mvn "$@" --file /project
}

# No args -> all integration tests (standard Surefire behavior)
# Otherwise, same convention as MineIt's run-tests.sh:
#   <class name>
#   <class name>#<test method>
if [ $# -eq 0 ]; then
    echo "▶ Running all integration tests"
    run_maven test
    exit 0
fi

ARG="$1"

if [[ "$ARG" == *"#"* ]]; then
    echo "▶ Running test method: $ARG"
    run_maven test -Dtest="$ARG"
    exit 0
fi

echo "▶ Running test class: $ARG"
run_maven test -Dtest="$ARG"
