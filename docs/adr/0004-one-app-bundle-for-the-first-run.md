# 0004. One app bundle for the first run

Status: Accepted

## Context

The PRD's Core loop milestone is the first one the owner can use end to end
without a terminal. Its Packaging row asked, before the milestone is called
done, how the parts reach the owner's Mac: the server and its database, the
Mac app, the helper that runs the providers' tools, and the reference
runner. [ADR 0001](0001-rails-api-postgresql-and-a-mac-client.md) put the
server and PostgreSQL in Docker containers on the owner's Mac for the first
run, and question 2 in [IMPLEMENTATION.md](../IMPLEMENTATION.md) leaves
notarization and a move to a real server out of this build. How the parts
are packaged, started and stopped is hard to change once the owner's log
lives in a Docker volume the app created, so it is recorded here
(rule AR-003). The PRD's Packaging, helper sign-in and token hand-over rows
carry the working assumptions (Q-5 to Q-7).

## Decision

1. **One bundle, built on the owner's Mac.** `scripts/build_app.sh` builds
   the API image as `leverage-api:<version>` (the version is
   `Leverage::VERSION`) in this Mac's Docker, pulls the PostgreSQL image
   `compose.yaml` pins by digest, builds `LeverageApp`, `LeverageHelper`
   and `LeverageRunner` in release mode, and assembles `dist/Leverage.app`.
   `Contents/MacOS/` holds the three programs. `Contents/Resources/` holds
   the icon (made from `mac/Packaging/AppIcon.svg` at build time) and a
   compose file made from the repository's by `scripts/app_compose.py`,
   which removes the `build:` line and sets `pull_policy: never` on `api`
   and `sweep`. `Info.plist` comes from `mac/Packaging/Info.plist`, with
   the bundle identifier `local.leverage.app` and the image tag in the key
   `LeverageAPIImageTag`. The bundle is signed ad hoc and not notarized, so
   it runs on the Mac that built it.
2. **The app starts the server.** At launch `ServerSupervisor` finds the
   `docker` program in four known folders, starts Docker Desktop with
   `open -a Docker` when the engine does not answer (waiting up to 120
   seconds), checks that the image is present, writes
   `<support folder>/server/` once (the compose file and a `.env` with
   generated database passwords, a generated `SECRET_KEY_BASE`, the image
   tag and the first free port from 47130 to 47139; folder mode 0700, files
   0600), runs `docker compose ... -p leverage-app up -d` with only `HOME`
   and `PATH` in docker's environment, and waits for `GET /v1/health`.
   Docker Desktop must already be installed; the app says so when it is
   not.
3. **The app starts the helper.** After the owner signs in,
   `HelperSupervisor` issues the helper's token and starts the bundled
   helper as a child process with the token in its environment only. A
   helper that exits on its own is started again with a new token, at most
   three times in a sliding minute; then the health line says agents are
   not running, with Try again.
4. **The app's life bounds the agents.** Closing the window leaves the app,
   the helper and the runs going. Quitting asks the helper to stop and
   waits up to 10 seconds. If the app dies without quitting, the helper's
   `ParentWatch` notices and stops its runs. One app runs per support
   folder (`AppLock`, a lock on `<support folder>/app.lock`); a second copy
   brings the first to the front and quits. The server's containers keep
   running after the app quits.

## Alternatives considered

- **A launch agent beside the app** that keeps the helper running without
  the window. It outlives the app, needs its own install step, and would
  need a stored helper token.
- **A notarized installer.** It needs a paid developer identity and a
  release process this build does not have (question 2).
- **The owner runs `docker compose` in a terminal.** That breaks the
  milestone's "without a terminal".

## Consequences

- Agents work only while the app is open.
- The bundle is built once by someone with Xcode and Docker on that Mac;
  the owner then opens it from Finder. Opening it from Finder (Gatekeeper,
  LaunchServices' environment) has not been tried; `scripts/smoke_app.sh`
  starts the program from a shell with a Finder-like environment.
- The owner's log lives in the Docker volume of the `leverage-app` project.
  Removing that project with its volumes, pruning Docker's volumes or
  resetting Docker Desktop destroys it, and nothing backs it up yet
  ([DEPLOY.md](../DEPLOY.md)).
- A later notarized build, or a helper that outlives the app, supersedes
  this record.
