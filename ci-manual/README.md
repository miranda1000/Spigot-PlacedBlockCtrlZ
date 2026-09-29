# ci-manual/

Runs PlacedBlockCtrlZ's integration tests against a Minecraft server *you* run, using only
WatchWolf-ClientsManager and the bots it spawns -- no WatchWolf-ServersManager, and no
WatchWolf-Server dispatcher plugin on the server either. Compare to the upstream flow, which asks a
running ServersManager (port 8000) to build and launch a server (with the dispatcher plugin
installed) for you; here, script 2 builds a much smaller server itself, once, and it stays up
across as many test runs as you like.

## Pipeline

| # | Script | What it does |
|---|--------|---------------|
| 1 | `1-compile-plugin.sh` | `mvn clean install -Dmaven.test.skip=true` in a disposable Maven container → `target/PlacedBlockCtrlZ-1.0.0.jar`. |
| 2 | `2-start-server.sh` | Builds a minimal server folder (a server jar copied from your local WatchWolf-ServersManager checkout + the jar from step 1, nothing else) and launches it with `docker run`, the same flags `DockerizedServerInstantiator` uses. Ops the test usernames via `ops.json`, waits for "Done (...)!" in the logs. |
| 3 | `3-start-clients-manager.sh` | Runs `bash ~/WatchWolf/ClientsManager/run.sh` and waits for port 7000. |
| 4 | `4-run-tests.sh` | Runs `PlacedBlockCtrlZShould` in a disposable Maven container on the host network, so it can reach the server (2) and ClientsManager (3) at `127.0.0.1`. |
| 5 | `5-stop-server.sh` | *(bonus, not one of the four above)* `docker stop`s the container from step 2. |

Run them in order:

```bash
ci-manual/1-compile-plugin.sh
ci-manual/2-start-server.sh
ci-manual/3-start-clients-manager.sh
ci-manual/4-run-tests.sh
```

Steps 2 and 3 only need to be (re-)run when you want a fresh server/ClientsManager; step 4 can be
run repeatedly against the same ones.

Before each test, the suite clears the configured bots' inventories and sets `randomTickSpeed`
to `0` in the test world. This prevents items from accumulating between runs and dirt from
turning into grass before undo returns it.

## Why there's a custom JUnit extension

WatchWolf-Tester's `AbstractTest` always opens a socket to a ServersManager and asks it to start a
server -- there's no supported way to skip that. `src/test/java/ManualServerTest.java` is a drop-in
replacement: same `beforeAll`/`afterAll` contract, so `PlacedBlockCtrlZShould`'s test bodies didn't
need much rework, but it:

- never opens a socket to a ServersManager, and never starts or stops a Minecraft server itself;
- doesn't talk to a WatchWolf-Server dispatcher plugin either -- `2-start-server.sh` doesn't
  install one, so there's nothing to connect to. Every `ServerPetition` method on `TesterConnector`
  (`setBlock`, `giveItem`, `setDifficulty`, ...) needs that dispatcher and would silently no-op
  without it, so this harness never calls them. Instead it adds `runCommand`/`setBlock`/`giveItem`/
  `isBlock` helpers that do the same job through a vanilla command run by one of the bots -- which
  is why `2-start-server.sh` ops the bot usernames up front (`OP_USERS`, via `ops.json`: vanilla
  `/give` and `/setblock` need permission level 2, and there's no dispatcher to grant that live);
- still talks to WatchWolf-ClientsManager on port 7000 exactly like `AbstractTest` does, to spawn
  and control the bot clients;
- has no config file and no whitelist -- `2-start-server.sh` sets `white-list=false`, so bots can
  join as soon as they're started. Test-specific settings (just the usernames, here) are a
  protected method (`getUsers()`) `PlacedBlockCtrlZShould` overrides in code;
- hands test methods their `TesterConnector` via `ParameterResolver` instead of
  `@ParameterizedTest`/`@ArgumentsSource`. `AbstractTest` needs an `ArgumentsProvider` (and a static
  instance-tracking map to go with it) because it runs each test once per server type; with a
  single server there's nothing to parameterize, so tests are plain `@Test` methods with a
  `TesterConnector` parameter.

See the class's Javadoc for the full list of `WATCHWOLF_*` environment variables it reads.

## Requirements

- Docker, reachable from your user (steps 1, 2 and 4).
- `python3` (step 2, to compute offline-mode UUIDs for `ops.json`).
- A WatchWolf-ServersManager checkout with a server jar already in place at
  `~/WatchWolf/ServersManager/ci/release/server-types/<SERVER_TYPE>/<SERVER_VERSION>.jar` (step 2;
  override the path with `SERVERS_MANAGER_PATH`).
- WatchWolf-ClientsManager already installed at `~/WatchWolf/ClientsManager` (step 3; override the
  path with `CLIENTS_MANAGER_PATH`).

## Common overrides

```bash
# use a different Minecraft/server type or version (must exist under server-types/)
SERVER_TYPE=Paper SERVER_VERSION=1.20.4 ci-manual/2-start-server.sh

# run a single test class/method
ci-manual/4-run-tests.sh PlacedBlockCtrlZShould
ci-manual/4-run-tests.sh 'PlacedBlockCtrlZShould#someTestMethod'
```

`OP_USERS` in `2-start-server.sh` is hardcoded to `user1 user2`, matching
`PlacedBlockCtrlZShould#getUsers()` exactly -- those are the only two bots this test suite ever
connects, so there's nothing to configure. If you add a test class that connects different
usernames, update `OP_USERS` to match.

The server script uses peaceful difficulty so hostile mobs cannot disrupt the tests, and
generates a superflat world using ServersManager's Minecraft 1.19 preset:
one layer of bedrock, two of dirt and one of grass in the plains biome. Stop the existing server
and rerun step 2 to recreate the server folder and world with these settings.
