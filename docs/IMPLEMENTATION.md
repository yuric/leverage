# Implementation progress

This file says where the build of leverage stands, so that any agent or
person can pick it up after an interruption.

## How to use this file

- **Read it first.** Before any work, read this file, then
  [AGENTS.md](../AGENTS.md).
- **Update it in the same pull request as the work.** A pull request that
  starts, finishes or changes the plan for a milestone edits the tables
  below. A milestone is `Merged` when its pull request is on `main` and
  every item and test the PRD's "Build order and tracks" assigns to it
  exists and passes in CI; the pull request description lists each with
  where it is.
- **Push each branch and open a draft pull request at once**, then record
  both under [In flight](#in-flight). Where this file and GitHub disagree,
  GitHub is right, and the next agent corrects this file first.
- **Keep it true.** It records what is done and what is in flight. What is
  built is defined in [PRD.md](PRD.md), how in
  [ARCHITECTURE.md](ARCHITECTURE.md), and how it is run in
  [DEPLOY.md](DEPLOY.md). Do not restate them here.
- **Questions for the owner go at the bottom**, each with what was chosen in
  the meantime and why. Remove a question when the owner answers it and the
  answer is recorded where it belongs.

## How the build is run

The owner delegated this build to one managing agent on 2026-11-19, under
the delegated-run rule in [CONTRIBUTING.md](../CONTRIBUTING.md). The managing
agent is Claude Code (Claude Fable 5.2); the run started on 2026-11-19 and
ends when the build is done or the owner stops it.

- The managing agent plans each milestone, gives the work to other agents,
  reviews what they return, merges, and keeps this file current. Agents it
  gives work to open pull requests but do not merge them.
- One pull request per milestone. Each leaves `main` working.
- Every pull request gets an adversarial review by a separate agent before it
  is merged, and its findings are fixed or answered in the pull request.
- Work follows the practices in
  [ARCHITECTURE.md](ARCHITECTURE.md#engineering-practices), test-driven
  development first.
- When something cannot be settled without the owner, the agent decides,
  records it under [Questions for the owner](#questions-for-the-owner), and
  continues.
- Anything that cannot be undone outside this repository waits. This term
  is the managing agent's choice, not the owner's; see question 3.
- Software is installed from official sources only, pinned, and listed under
  [Installed for the build](#installed-for-the-build).
- No agent signs in to a provider or types a credential. Tests against real
  providers use only tools that are already signed in on the owner's Mac.

## Current state

| | |
| --- | --- |
| **As of** | 2026-11-19 |
| **On `main`** | The rules, the PRD with the gate settled, the first decision record, the design reference and the provider-terms record |
| **Next** | The contract milestone, once the skeleton is merged |

### In flight

| Work | Branch | Pull request | State |
| --- | --- | --- | --- |
| Milestone 0 skeleton | `chore/skeleton` | #10 | In review |

## Milestones

The milestones and their content are defined in the PRD under "Build order
and tracks". This table tracks them; it does not define them. Its rows follow
the PRD's milestone list. How the build is run locally is in
[DEPLOY.md](DEPLOY.md).

| # | Milestone | Status | Pull request | Notes |
| --- | --- | --- | --- | --- |
| 0 | Skeleton | In review | #10 | Not a PRD milestone; it gives the others a place to land. Adds the first product source file, so it activates AR-006 and AR-007: it names the mechanisms and adds the AR-007 check. It lists a second component, so it activates AR-005 too. Its versions and test tools are in [ADR 0002](adr/0002-pinned-versions-test-tools-and-code-units.md) |
| 1 | Contract | Not started | | |
| 2 | Core loop | Not started | | With account setup and the part that starts agents. The first milestone usable without a terminal |
| 3 | Handoff | Not started | | |
| 4 | Rule checks | Not started | | |
| 5 | Questions and approvals | Not started | | |
| 6 | Credentials | Not started | | The last milestone of this build; the release acceptance run follows it |
| 7 | Analytics page | Not in this build | | See question 1 |

Status is one of `Not started`, `In progress`, `In review`, `Merged`,
`Not in this build`.

## Decisions made during the build

Hard-to-reverse choices are recorded as ADRs in [adr/](adr/). Smaller choices
an agent made without the owner are listed here until the owner has seen
them.

- **`API_PORT`.** `compose.yaml` publishes the API on `127.0.0.1` at the
  port in `API_PORT`, 3000 by default, because port 3000 on the owner's Mac
  was already taken by another program during the skeleton's checks.
- **TLS switches.** `RAILS_ASSUME_SSL` and `RAILS_FORCE_SSL` default to on
  in production mode, and `.env.example` turns both off, because the API is
  served over plain HTTP on `127.0.0.1` during the first run.
- **The API's tests run in the production image.** compose has one `api`
  service built from Rails' default production Dockerfile, and
  `bin/rails test` switches to the test environment and its own database.
- **Brakeman, `bundler-audit` and the local CI runner left out.** All
  three are `rails new` defaults. `bin/ci` and `config/ci.rb` were never
  run. The two gems were removed because of their licenses; see question 6.
- **Images pinned by digest.** `api/Dockerfile` and `compose.yaml` name each
  image by tag and digest; ADR 0002 records the digests.

## Installed for the build

Nothing was installed on the owner's Mac. Every Ruby command ran in a
container, and Swift ran with the Xcode already installed (Xcode 26.6,
build 17F113, Swift 6.3.3).

| What | Version | Source | Used for |
| --- | --- | --- | --- |
| `ruby` image | `4.0.10-trixie` | Docker Hub official image | Running `rails new` once; no file refers to it |
| `ruby` image | `4.0.10-slim` (digest in ADR 0002) | Docker Hub official image | The base of the API image |
| `postgres` image | `17.12-trixie` (digest in ADR 0002) | Docker Hub official image | The `db` service |
| Debian packages in `api/Dockerfile` | As Debian 13 ships them at build time | Debian 13 archive, inside the API image | `curl`, `libjemalloc2`, `postgresql-client`; and to build gems: `build-essential`, `git`, `libpq-dev`, `libyaml-dev`, `pkg-config` |
| Gems in `api/Gemfile.lock` | As locked | RubyGems, installed inside the API image | The API, its tests and its checks |
| `markdownlint-cli2` | 0.24.1 | npm, fetched by `npx` | Running the Markdown lint; not part of the repository |

The direct gems, their licenses and why each is needed are listed in the
skeleton's pull request description, as rule AR-004 asks.

## Questions for the owner

1. **The Analytics page.** The PRD gives it its own PRD, which does not
   exist. *Chosen meanwhile:* it is left out of this build.
2. **A notarized installer and a move to a real server.** *Chosen meanwhile:*
   neither is part of this build; the backend runs in containers on the
   owner's Mac and the Mac app is built and run there.
3. **Waiting before anything irreversible outside this repository.** The
   owner's terms do not say this. *Chosen meanwhile:* the managing agent
   holds any such step and records it here, because it cannot be undone
   while the owner is away.
4. **The PRD's open decisions that the build will reach.** The PRD's "Open
   decisions" table lists what is not settled, among them what carries out a
   task on an API token, how a credential's model is set, how the helper
   signs in to the server, and how the parts are installed without a
   terminal. *Chosen meanwhile:* the managing agent settles each one when
   the build reaches it, records the choice here and in the PRD, and
   continues.
5. **The choices made for the owner in the PRD gate change.** The owner
   asked the agent to settle every review finding in the gate and to review
   them afterwards. The pull request that made that change lists each
   choice in one sentence with its alternative.
6. **Security scanners for the API, and their licenses.** `rails new` adds
   Brakeman (a security scan of the code) and `bundler-audit` (a check of
   the gems for known defects). Rule AR-004 asks that a tool's license be
   compatible with the MIT License. According to RubyGems, Brakeman 8.1.0
   is under the "Brakeman Public Use License", which is not an open source
   license, and `bundler-audit` 0.9.3 is under GPL-3.0-or-later. Both are
   tools that run beside the code and are not part of it. *Chosen
   meanwhile:* both are removed, because a delegated run does not answer
   Deviates to a rule, so the API has no security scanner in CI. The
   alternative is to keep them and say in AR-004 that the license clause
   covers what is built into the product, not the tools that check it.
   Putting either back is one line in `api/Gemfile` and one CI step.

## Waiting for the owner

Merged pull requests keep both AI-assistance boxes unticked until the owner
reads each one and ticks the second box. Every ADR added in the delegated
run is also listed here until the owner has read it.

| Item | What is waiting |
| --- | --- |
| Pull requests 3 to 7 | Merged on the owner's instruction before the run started; their AI-assistance boxes are unticked |
| Pull requests 8, 9 and 10 | Merged in the delegated run after an adversarial review; their AI-assistance boxes are unticked. Pull request 9 lists the choices made for the owner in the PRD |
| [ADR 0001](adr/0001-rails-api-postgresql-and-a-mac-client.md) | Records the owner's decisions; the owner has not read its text. Two points in it are the agent's: the directory names `api/` and `mac/`, and the helper written in Swift |
| [ADR 0002](adr/0002-pinned-versions-test-tools-and-code-units.md) | Added in the delegated run: the pinned versions, the test tools and the code units of the skeleton. The owner has not read it |
