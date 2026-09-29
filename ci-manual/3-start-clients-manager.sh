#!/usr/bin/env bash
# Starts WatchWolf-ClientsManager. Per the WatchWolf setup, this is just:
#
#   bash ~/WatchWolf/ClientsManager/run.sh
#
# run.sh already launches its own container in the background (the same way
# WatchWolf-ServersManager/ci/release/run.sh does, with `docker run -d`), so this wrapper doesn't
# need to detach anything itself -- it just calls run.sh, then waits for port 7000 to actually
# answer before handing control back, so ci-manual/4-run-tests.sh never races a ClientsManager
# that's still booting.
set -e

CLIENTS_MANAGER_PATH="${CLIENTS_MANAGER_PATH:-$HOME/WatchWolf/ClientsManager}"
CLIENTS_MANAGER_HOST="${WATCHWOLF_CLIENTSMANAGER_HOST:-127.0.0.1}"
CLIENTS_MANAGER_PORT="${WATCHWOLF_CLIENTSMANAGER_PORT:-7000}"
READY_TIMEOUT="${CLIENTS_MANAGER_READY_TIMEOUT:-60}"

port_open() {
    (exec 3<>"/dev/tcp/$CLIENTS_MANAGER_HOST/$CLIENTS_MANAGER_PORT") 2>/dev/null
}

if port_open; then
    echo "==> ClientsManager is already answering on $CLIENTS_MANAGER_HOST:$CLIENTS_MANAGER_PORT; not starting a second one."
    exit 0
fi

RUN_SCRIPT="$CLIENTS_MANAGER_PATH/run.sh"
if [ ! -f "$RUN_SCRIPT" ]; then
    echo "[e] $RUN_SCRIPT not found." >&2
    echo "    Install WatchWolf-ClientsManager first (see WatchWolfSetup.sh), or set CLIENTS_MANAGER_PATH." >&2
    exit 1
fi

echo "==> Starting WatchWolf-ClientsManager ($RUN_SCRIPT)"
bash "$RUN_SCRIPT"

echo "==> Waiting up to ${READY_TIMEOUT}s for $CLIENTS_MANAGER_HOST:$CLIENTS_MANAGER_PORT..."
deadline=$(( $(date +%s) + READY_TIMEOUT ))
until port_open; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
        echo "[e] ClientsManager never answered on $CLIENTS_MANAGER_HOST:$CLIENTS_MANAGER_PORT within ${READY_TIMEOUT}s." >&2
        exit 1
    fi
    sleep 1
done

echo "==> ClientsManager is up on $CLIENTS_MANAGER_HOST:$CLIENTS_MANAGER_PORT"
