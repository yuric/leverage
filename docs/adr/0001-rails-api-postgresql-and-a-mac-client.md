# 0001. Rails API with PostgreSQL, a Mac client and a Mac helper

Status: Accepted

## Context

leverage lets one owner coordinate AI agents from several providers. The PRD's
open decisions "Stack and hosting" and "Where it runs" recommended one server
process with PostgreSQL per owner, and no document named a language or a
framework. Nothing can be built until those are chosen.

Three facts shaped the choice:

- The first run uses subscription logins for Claude, Codex, Gemini and Grok.
  A subscription login lives inside the provider's own tool on the owner's
  Mac.
- The project is open source, so a credential must never be in the
  repository, in a log, in an event or in a test fixture.
- leverage is its own product. It shares no code, usage readers or
  credentials with Campus.

The owner made the decisions below on 2026-11-18.

## Decision

1. The backend is a Ruby on Rails application in API mode. It is the only
   writer of state: the event log, the task state machine and the rules live
   there.
2. PostgreSQL is its only datastore.
3. The backend runs on a server the owner controls, one installation per
   owner.
4. The owner's interface is a Mac app. It is a thin client: every change goes
   through the API, and the app keeps nothing the API does not already hold.
5. A helper runs on the owner's Mac. It starts each provider's own tool with
   the login that tool already holds, and reports to the API. A subscription
   login never leaves the Mac and never reaches the server.
6. The backend and the Mac app live in separate top-level directories of this
   repository, `api/` and `mac/`.

## Alternatives considered

- **The backend on the owner's Mac, next to the app.** Nothing to host, and
  the logins are already there. The owner chose a server he controls instead.
- **A hosted service for many owners.** The PRD calls this a different build,
  with row-level security and an operator view. It is not version 1.
- **API tokens for the first run.** A token could be held by the server and
  would need no helper. The owner chose subscription logins first.
- **Building on Campus.** The PRD recommended reusing Campus's credentials
  work. The owner chose to keep the two products separate.

## Consequences

- Agents work only while the Mac that holds the logins is on, because the
  helper drives the providers' tools there. The server keeps the record in
  the meantime.
- The server holds no provider login, so it cannot call a model itself. The
  orchestrator therefore runs as a seat through the helper, like any other
  agent.
- The helper and the Mac app talk to a server over a network. How they prove
  who they are, and what the connection protects, must be written under
  Trust boundaries before the first code that crosses it.
- This record does not choose the Mac app's toolkit, or the helper's language
  and its place in the repository. Each needs its own record before its first
  code.
- The versions of Ruby, Rails and PostgreSQL are pinned by the pull request
  that adds the first manifest, as rule AR-004 requires.
- The PRD's open decisions "Stack and hosting", "Where it runs" and "Is this
  product Campus" are answered here and are updated in the PRD separately.
