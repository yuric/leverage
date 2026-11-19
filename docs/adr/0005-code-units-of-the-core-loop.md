# 0005. Code units of the core loop

Status: Accepted

## Context

[ADR 0002](0002-pinned-versions-test-tools-and-code-units.md) listed four
code units: `api`, `LeverageKit`, `LeverageApp` and `LeverageHelper`. The
Core loop milestone adds a program that drives a provider's tool for a seat
(the PRD's reference runner), the app's services that start Docker, the
server and the helper, shared test support, and an end-to-end test that runs
the helper and the runner against the real API. The whole loop also has to
run in CI, where macOS runners cannot run Docker. Each new unit is a
component boundary that rule AR-005 checks, and the list of units is hard
to change once code imports along it (rule AR-003).

## Decision

1. **The reference runner is its own executable, `LeverageRunner`**, which
   imports only `LeverageKit`. The helper starts it as a process for each
   seat it runs and hands it an environment; the runner and the helper never
   import each other.
2. **`LeverageAppServices`** is a library with no SwiftUI that imports only
   `LeverageKit`: finding Docker, writing the server folder, starting the
   server and the helper, the app lock and the session store. `LeverageApp`
   imports it and `LeverageKit`, and never the helper or the runner.
3. **Test units.** `LeverageTestSupport` (stand-in tool locator, temporary
   folders, `StubURLProtocol`, the in-memory fakes of the three API
   protocols and of the app's runtime) imports only `LeverageKit`. Each
   product unit has its own test unit, and `LeverageEndToEndTests` imports
   `LeverageKit` and `LeverageTestSupport` and runs the built helper and
   runner as processes. `mac/Tests/StandIns/` holds the stand-in tools in
   Python and shell; it is not a code unit.
4. **Build subsets.** `mac/Package.swift` reads `LEVERAGE_ONLY` and
   declares only that lane's targets: `kit`, `runner`, `helper`,
   `services`, `app` (without `LeverageAppServices`, where `Live.swift`
   gives an unavailable runtime) and `e2e` (`LeverageKit`, `LeverageRunner`,
   `LeverageHelper`, `LeverageTestSupport`, `LeverageEndToEndTests`). Unset,
   it declares every target on macOS and the `e2e` lane on Linux.
5. **A Linux build for CI.** The `e2e` job in `.github/workflows/ci.yml`
   runs on `ubuntu-24.04` with the runner image's own Swift: it builds the
   `e2e` lane and runs `scripts/e2e_core_loop.sh` with the API in its
   containers. Code in that lane uses Foundation and the C library only
   (`posix_spawn` for child processes) and imports `FoundationNetworking`
   where it exists.

The directions are the table under
[Allowed dependency directions](../ARCHITECTURE.md#allowed-dependency-directions);
`scripts/check_imports.py` checks them.

## Alternatives considered

- **The runner inside the helper.** One program fewer, but a stop of one
  seat could not end its tool's whole process group without the helper's
  own, and a fault in one run would take every run down.
- **The app's services inside `LeverageApp`.** They could not be tested
  without SwiftUI, and the app lane could not be built while they changed.
- **No Linux build: a fake server on the Mac side.** It would test the
  helper and the runner against a second implementation of the API instead
  of the API.

## Consequences

- Thirteen code units, all in one Swift package with no third-party
  package, plus `api`.
- The `e2e` lane must keep building on Linux. Its first Linux compile is
  the `e2e` job's first run; if it cannot be made to build there in two
  attempts, the job is removed and `scripts/e2e_core_loop.sh` stays a
  required local step (the plan's fallback, listed for the owner).
- A new unit, or a new direction, changes the table and this record's
  successor.
