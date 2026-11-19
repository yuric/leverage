# 0001. Rails API with PostgreSQL, a Mac client and a Mac helper

Status: Accepted

## Context

leverage lets one owner coordinate AI agents from several providers. The PRD's
open decisions "Stack and hosting" and "Where it runs" recommended one server
process with PostgreSQL per owner, and no document named a language or a
framework. Nothing can be built until those are chosen.

The PRD's workspace lock and state trigger are written for PostgreSQL.

Three facts shaped the choice:

- The first run uses subscription logins for Claude, Codex, Gemini and Grok.
  A subscription login lives inside the provider's own tool on the owner's
  Mac.
- The project is open source, so a secret must never be in the repository,
  in a log, in an event, in a test fixture or in a screenshot. Records name a
  credential by its id only.
- leverage is its own product. It shares no code, usage readers, storage or
  credentials with Campus.

The owner made the decisions below on 2026-11-18 and 2026-11-19.

## Decision

1. The backend is a Ruby on Rails application in API mode. It is the only
   writer of state: the event log, the task state machine and the rules live
   there.
2. PostgreSQL is its only datastore.
3. The backend runs on a server the owner controls, one installation per
   owner.
4. The owner's interface is a Mac app, a thin client of the API: every change
   to the record goes through the API. There is no web app.
5. A helper runs on the owner's Mac. It starts each provider's own tool with
   the login that tool already holds, and reports to the API. A subscription
   login never leaves the Mac and never reaches the server.
6. The backend and the Mac app live in separate top-level directories of this
   repository, `api/` and `mac/`.
7. leverage is not Campus. Nothing is shared with Campus: no code, no usage
   readers, no storage, no credentials.
8. The Mac app is a native app, written in Swift with SwiftUI.
9. The backend is shipped as a container image. For the first run the backend
   and PostgreSQL run in Docker containers on the owner's Mac; later the same
   containers move to the server the owner controls.
10. The helper is written in Swift and lives in `mac/` with the Mac app.

## Alternatives considered

- **The backend on the owner's Mac for good, next to the app.** Nothing to
  host, and the logins are already there. The owner chose a server the owner
  controls instead, and runs the containers on the Mac only for the first
  run.
- **The backend directly on the Mac, without containers.** The owner chose
  containers, so that the same containers move to the server later.
- **A hosted service for many owners.** The PRD calls this a different build,
  with row-level security and an operator view. It is not version 1.
- **A web app.** The PRD was written with a web app as the owner's interface.
  The owner chose a Mac app, and there is no web app.
- **A web-view shell around the HTML mockup.** It would reuse the mockup's
  markup. The owner chose a native app instead.
- **API tokens held by the server.** A server-held token would need no
  helper. The owner chose subscription logins for the first run. API tokens
  stay in version 1 as a second kind of credential, and they are kept on the
  Mac like logins: in the provider's own tool or the Mac's keychain, never on
  the server.
- **Building on Campus.** The PRD recommended reusing Campus's credentials
  work. The owner chose to keep the two products separate.

## Consequences

- Agents work only while the Mac that holds the logins is on, because the
  helper drives the providers' tools there. Once the backend is on the
  server, the server keeps the record in the meantime; during the first run
  the backend is on the same Mac and is off with it.
- The server holds no provider login, so it cannot call a model itself. The
  orchestrator therefore runs as a seat through the helper, like any other
  agent.
- The server never holds a secret. For each credential it stores the id,
  kind, provider, display name and readings. Provider logins and API tokens
  stay on the Mac, inside the provider's own tool or the Mac's keychain.
  Records name a credential by its id only.
- The helper is a separate program from the API, because the two run on
  different machines. It signs in to the API with its own token, and the
  contract defines its calls. This replaces the PRD's line that makes the
  machine helper part of the server.
- The helper and the Mac app reach the server over a network. How the Mac
  app signs in, how the helper's token is issued, and what the connection
  protects must be written under Trust boundaries before the first code that
  crosses it.
- The versions of Ruby, Rails, PostgreSQL, Swift and the container base
  images are pinned by the pull requests that add the first manifests, as
  rule AR-004 requires.
- The PRD's open decisions "Stack and hosting", "Where it runs", "How the
  orchestrator runs" and "Is this product Campus" are answered here. The PRD
  is updated separately: those rows, every place it says "web app", the line
  that makes the machine helper part of the server, and the lines that build
  on Campus.
