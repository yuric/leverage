# Implementation progress

This file says where the build of leverage stands, so that any agent or
person can pick it up after an interruption.

## How to use this file

- **Read it first.** Before any work, read this file, then
  [AGENTS.md](../AGENTS.md).
- **Update it in the same pull request as the work.** A pull request that
  starts, finishes or changes the plan for a milestone edits the tables
  below. A milestone is `Merged` only when its pull request is on `main`.
- **Keep it true.** It records what is done and what is in flight. What is
  built is defined in [PRD.md](PRD.md), how in
  [ARCHITECTURE.md](ARCHITECTURE.md), and how it is run in
  [DEPLOY.md](DEPLOY.md). Do not restate them here.
- **Questions for the owner go at the bottom**, each with what was chosen in
  the meantime and why. Remove a question when the owner answers it and the
  answer is recorded where it belongs.

## How the build is run

The owner delegated this build to one managing agent on 2026-11-19, under
the delegated-run rule in [CONTRIBUTING.md](../CONTRIBUTING.md).

- The managing agent plans each milestone, gives the work to other agents,
  reviews what they return, and keeps this file current.
- One pull request per milestone. Each leaves `main` working.
- Every pull request gets an adversarial review by a separate agent before it
  is merged, and its findings are fixed or answered in the pull request.
- Work follows the practices in
  [ARCHITECTURE.md](ARCHITECTURE.md#engineering-practices), test-driven
  development first.
- When something cannot be settled without the owner, the agent decides,
  records it under [Questions for the owner](#questions-for-the-owner), and
  continues. Anything that cannot be undone outside this repository waits.
- Software is installed from official sources only, pinned, and listed under
  [Installed for the build](#installed-for-the-build).
- No agent signs in to a provider or types a credential. Tests against real
  providers use only tools that are already signed in on the owner's Mac.

## Current state

| | |
| --- | --- |
| **As of** | 2026-11-19 |
| **On `main`** | The rules, the PRD, the first decision record, the design reference and the provider-terms record |
| **In flight** | The PRD change that settles the gate before the contract; the project skeleton |
| **Next** | The contract milestone, once the PRD change is merged |

## Milestones

The milestones and their content are defined in the PRD under "Build order
and tracks". This table tracks them; it does not define them.

| # | Milestone | Status | Pull request | Notes |
| --- | --- | --- | --- | --- |
| 0 | Skeleton: the `api/` and `mac/` directories, containers and CI | In progress | | Not a PRD milestone; it gives the others a place to land |
| 1 | Contract | Not started | | Waits for the PRD gate change |
| 2 | Core loop, account setup and the part that starts agents | Not started | | The first milestone usable without a terminal |
| 3 | Handoff | Not started | | |
| 4 | Rule checks | Not started | | |
| 5 | Questions and approvals | Not started | | |
| 6 | Credentials | Not started | | |
| 7 | Local deployment and the release acceptance run | Not started | | The backend in containers on the owner's Mac; the Mac app built and run there |

Status is one of `Not started`, `In progress`, `In review`, `Merged`.

## Decisions made during the build

Hard-to-reverse choices are recorded as ADRs in [adr/](adr/). Smaller choices
an agent made without the owner are listed here until the owner has seen
them.

| Date | Choice | Where it is recorded |
| --- | --- | --- |
| 2026-11-19 | The directory names `api/` and `mac/`, and the helper written in Swift | [ADR 0001](adr/0001-rails-api-postgresql-and-a-mac-client.md) |

## Installed for the build

Nothing yet.

## Questions for the owner

1. **The Analytics page.** The PRD gives it its own PRD, which does not
   exist. *Chosen meanwhile:* it is left out of this build.
2. **A notarized installer and a move to a real server.** *Chosen meanwhile:*
   neither is part of this build; the backend runs in containers on the
   owner's Mac and the Mac app is built and run there.
3. **The AI-assistance box on each merged pull request.** Only the owner can
   tick it, after reading the pull request. Every pull request merged under
   the delegated run is waiting for that.
