#!/usr/bin/env bash
# Prepares a minimal server folder -- just the compiled PlacedBlockCtrlZ jar on top of a server jar
# you already have locally, no WatchWolf-Server -- and launches it with Docker, the same way
# WatchWolf-ServersManager's DockerizedServerInstantiator does:
#
#   docker run -d --rm --name "$id" \
#       -p "$SERVER_PORT:25565/tcp" -p "$SERVER_PORT:25565/udp" \
#       -v "$WORK_DIR":/server \
#       "eclipse-temurin:$JAVA_VERSION-jdk" \
#       /bin/sh -c "java -XX:MaxRAMFraction=1 -jar server.jar nogui"
#
# No downloads: the server jar is read straight from your local WatchWolf-ServersManager checkout,
# the same place ServersManager itself reads it from (ci/release/server-types/<type>/<version>.jar).
# There's no ServersManager process orchestrating this, so this script builds the folder and calls
# `docker run` itself, once, and leaves the container running for repeated test runs.
#
# There's no WatchWolf-Server plugin either, so there's nothing to grant OP through remotely; the
# bot usernames that need to run commands (see ManualServerTest#setBlock/#giveItem/#isBlock) are
# opped up front instead, by writing ops.json directly (OP_USERS below).
set -e

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
PROJECT_ROOT="$(realpath "$SCRIPT_DIR/..")"

# --- configuration (all overridable via environment variables) ---------------------------------
PLUGIN_JAR="${PLUGIN_JAR:-$PROJECT_ROOT/target/PlacedBlockCtrlZ-1.0.0.jar}"

SERVERS_MANAGER_PATH="${SERVERS_MANAGER_PATH:-$HOME/WatchWolf/ServersManager}"
SERVER_TYPE="${SERVER_TYPE:-Spigot}"
SERVER_VERSION="${SERVER_VERSION:-1.19}"
SERVER_JAR="$SERVERS_MANAGER_PATH/ci/release/server-types/$SERVER_TYPE/$SERVER_VERSION.jar"

# Must match PlacedBlockCtrlZShould#getUsers() -- these are the only two bots the test ever
# connects, so there's no reason to make this configurable.
OP_USERS="user1 user2"

SERVER_PORT="${WATCHWOLF_SERVER_PORT:-25565}"
CONTAINER_NAME="${CONTAINER_NAME:-watchwolf-manual-server}"
WORK_DIR="${WORK_DIR:-$SCRIPT_DIR/server-run}"
STARTUP_TIMEOUT="${STARTUP_TIMEOUT:-300}"    # seconds to wait for "Done (...)!" in the server log

# --- sanity checks ------------------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
    echo "[e] Docker is required (WatchWolf-ServersManager launches every server in its own container)." >&2
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "[e] python3 is required to compute offline-mode UUIDs for ops.json." >&2
    exit 1
fi

if [ ! -f "$PLUGIN_JAR" ]; then
    echo "[e] $PLUGIN_JAR not found. Run ci-manual/1-compile-plugin.sh first (or set PLUGIN_JAR)." >&2
    exit 1
fi

if [ ! -f "$SERVER_JAR" ]; then
    echo "[e] $SERVER_JAR not found." >&2
    echo "    Set SERVER_TYPE/SERVER_VERSION, or SERVERS_MANAGER_PATH if WatchWolf-ServersManager isn't at $SERVERS_MANAGER_PATH." >&2
    exit 1
fi

if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    echo "[e] A container named '$CONTAINER_NAME' already exists. Stop/remove it first:" >&2
    echo "      docker rm -f $CONTAINER_NAME" >&2
    exit 1
fi

# --- pick the JDK image for this Minecraft version ----------------------------------------------
# Mirrors dev.watchwolf.core.utils.DockerUtilities.getJavaVersion (see the ServersManager README):
# Java 8 below 1.17, 16 for 1.17, 17 up to 1.20.4, 21 from 1.20.5.
version_ge() { # version_ge A B -> true if A >= B, comparing dotted numbers
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]
}
JAVA_VERSION="${JAVA_VERSION:-}"
if [ -z "$JAVA_VERSION" ]; then
    if version_ge "$SERVER_VERSION" "1.20.5"; then JAVA_VERSION=21
    elif version_ge "$SERVER_VERSION" "1.18"; then JAVA_VERSION=17
    elif version_ge "$SERVER_VERSION" "1.17"; then JAVA_VERSION=16
    else JAVA_VERSION=8
    fi
fi
DOCKER_IMAGE="eclipse-temurin:${JAVA_VERSION}-jdk"
echo "==> $SERVER_TYPE $SERVER_VERSION -> $DOCKER_IMAGE"

# --- prepare a minimal server folder --------------------------------------------------------------
echo "==> Preparing server folder at $WORK_DIR"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR/plugins"

cp "$SERVER_JAR" "$WORK_DIR/server.jar"
cp "$PLUGIN_JAR" "$WORK_DIR/plugins/$(basename "$PLUGIN_JAR")"

echo "eula=true" > "$WORK_DIR/eula.txt"

# Minecraft 1.19 superflat preset, matching ServersManager's modern flat generator settings:
# one bedrock layer, two dirt layers and one grass layer in the plains biome.
# No whitelist: anyone (the bots included) can join straight away.
cat > "$WORK_DIR/server.properties" <<EOF
online-mode=false
white-list=false
motd=Minecraft test server
max-players=100
difficulty=peaceful
level-type=FLAT
generator-settings={"layers":[{"block":"minecraft:bedrock","height":1},{"block":"minecraft:dirt","height":2},{"block":"minecraft:grass_block","height":1}],"biome":"minecraft:plains"}
op-permission-level=4
spawn-protection=0
server-port=25565
EOF

# ops.json: no WatchWolf-Server to grant OP through live, so the bots that need to run commands
# (setblock/give/execute -- see ManualServerTest) are opped up front. Offline-mode UUIDs are
# deterministic (UUID.nameUUIDFromBytes("OfflinePlayer:<name>")), so this doesn't need the server's
# help either.
echo "==> Opping: $OP_USERS"
# shellcheck disable=SC2086 # intentional word-splitting: OP_USERS is a space-separated list
python3 - "$WORK_DIR/ops.json" $OP_USERS <<'PY'
import hashlib, json, sys

out_path = sys.argv[1]
users = sys.argv[2:]

def offline_uuid(name):
    h = bytearray(hashlib.md5(("OfflinePlayer:" + name).encode("utf-8")).digest())
    h[6] = (h[6] & 0x0f) | 0x30  # version 3
    h[8] = (h[8] & 0x3f) | 0x80  # IETF variant
    return "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x" % tuple(h)

ops = [{"uuid": offline_uuid(u), "name": u, "level": 4, "bypassesPlayerLimit": False} for u in users]
with open(out_path, "w") as f:
    json.dump(ops, f, indent=2)
PY

echo "==> Server folder ready:"
find "$WORK_DIR" -maxdepth 2 -not -path "$WORK_DIR" | sed "s|$WORK_DIR|  .|"

# --- launch, the same way DockerizedServerInstantiator does --------------------------------------
echo "==> Starting $CONTAINER_NAME (game :$SERVER_PORT)"
docker run -d --rm --name "$CONTAINER_NAME" \
    -p "$SERVER_PORT:25565/tcp" -p "$SERVER_PORT:25565/udp" \
    -v "$WORK_DIR":/server \
    -w /server \
    "$DOCKER_IMAGE" \
    /bin/sh -c "java -XX:MaxRAMFraction=1 -jar server.jar nogui" \
    > /dev/null

echo "==> Waiting up to ${STARTUP_TIMEOUT}s for the server to report ready..."
deadline=$(( $(date +%s) + STARTUP_TIMEOUT ))
started=0
while [ "$(date +%s)" -lt "$deadline" ]; do
    if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
        echo "[e] Container $CONTAINER_NAME exited before starting up. Last log lines:" >&2
        docker logs --tail 40 "$CONTAINER_NAME" 2>&1 >&2 || true
        exit 1
    fi
    if docker logs "$CONTAINER_NAME" 2>&1 | grep -qE 'Done \([^)]+\)! For help, type "help"'; then
        started=1
        break
    fi
    sleep 2
done

if [ "$started" -ne 1 ]; then
    echo "[e] Server didn't report ready within ${STARTUP_TIMEOUT}s. Last log lines:" >&2
    docker logs --tail 40 "$CONTAINER_NAME" 2>&1 >&2 || true
    echo "    It may still come up -- check with: docker logs -f $CONTAINER_NAME" >&2
    exit 1
fi

echo "==> $CONTAINER_NAME is up."
echo "    Game port: 127.0.0.1:$SERVER_PORT"
echo "    Logs:      docker logs -f $CONTAINER_NAME"
echo "    Stop:      docker stop $CONTAINER_NAME"
echo
echo "Now run ci-manual/3-start-clients-manager.sh, then ci-manual/4-run-tests.sh."
