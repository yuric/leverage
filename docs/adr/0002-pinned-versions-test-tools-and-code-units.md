# 0002. Pinned versions, test tools and code units of the skeleton

Status: Accepted

## Context

[ADR 0001](0001-rails-api-postgresql-and-a-mac-client.md) chose a Rails API
with PostgreSQL in Docker containers, and a Mac app and a helper in Swift,
and left the versions to the pull request that adds the first manifests.
The skeleton is that pull request: it adds `api/Gemfile`, `api/Dockerfile`,
`compose.yaml` and `mac/Package.swift`, and the first product source. Rule
AR-003 asks for a record of the versions, the tools that test the code, and
the component boundaries it draws.

The versions were checked on 2026-11-19 against RubyGems, Docker Hub and
GitHub's list of runner images, not taken from memory.

## Decision

1. **Ruby 4.0.10**, the newest stable release on Docker Hub's official
   `ruby` image (4.1 is a preview). The API image is built from
   `ruby:4.0.10-slim`; `api/.ruby-version` names the same version.
2. **Rails 8.1.4.1**, the newest release on RubyGems, in API mode. Action
   Mailer, Action Mailbox, Action Text, Active Storage, Action Cable,
   Kamal, Thruster, the Solid gems and Jbuilder are left out, because
   version 1 has no use for them yet. Every gem version is fixed in
   `api/Gemfile.lock`.
3. **PostgreSQL 17.12**, from the official image `postgres:17.12-trixie`.
4. **Minitest**, the Rails default, tests the API, with Rails' request
   tests. **RuboCop** (`rubocop-rails-omakase`) checks its style and
   **Brakeman** checks it for security problems; both are Rails defaults.
5. **Swift tools version 6.2**, with macOS 14 as the oldest supported
   system. 6.2 is the Swift in Xcode 26.0, the oldest Xcode on GitHub's
   `macos-26` runner image, so every Xcode on that image builds the
   package. **Swift Testing** tests it; it ships with the toolchain. The
   package uses no third-party package.
6. **GitHub Actions** runs the checks: the API's tests, RuboCop and
   Brakeman through `compose.yaml` on `ubuntu-24.04`, the Swift build and
   tests on `macos-26`, and the import check.
7. **Code units.** The API is one code unit, `api/`. The Swift package
   `Leverage` in `mac/` has three: `LeverageKit`, the library that is the
   Mac side's one client of the API; `LeverageApp`, the app; and
   `LeverageHelper`, the helper. The app and the helper may import
   `LeverageKit` and not each other, `LeverageKit` imports no other unit,
   and the Mac side reaches the API only over HTTP. The list lives under
   Components in [ARCHITECTURE.md](../ARCHITECTURE.md#allowed-dependency-directions).

## Alternatives considered

- **Ruby 4.1.** Only a preview and a release candidate exist.
- **RSpec instead of Minitest.** It adds gems and gives version 1 nothing
  that Rails' own test tools lack.
- **XCTest instead of Swift Testing.** Both ship with Xcode. Swift Testing
  is the newer of the two and runs tests in parallel by default.
- **A newer Swift tools version.** It would rule out the older Xcode
  versions on the runner image and gives the skeleton nothing.
- **The app and the helper with their own copies of the client.** Two
  clients of one API would drift apart; one library keeps every call in
  one place.

## Consequences

- The tests run in the same image the API ships in. `bin/rails test` sets
  the test environment itself, and the tests use their own database.
- Package versions change only through a pull request, which answers rule
  AR-004 for what it changes.
- `macos-15`'s default Xcode, 16.4, cannot build the package; CI uses
  `macos-26`.
- Brakeman and `bundler-audit` are development and test tools, and the
  default Dockerfile puts them in the image. Their licenses, the "Brakeman
  Public Use License" and GPL-3.0-or-later, are an open question against
  rule AR-004, recorded in [IMPLEMENTATION.md](../IMPLEMENTATION.md).
- A new code unit, or a new direction between units, needs a change to the
  list and a new ADR.
