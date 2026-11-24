# 0003. The contract's format

Status: Accepted

## Context

The PRD's Contract milestone asks that what the parts of Leverage share be
written down and reviewed before any part is built: the tables of the Data
model, the fixed lists with the event payloads, the state, step, hook, job,
role and timer tables, the agent, owner and helper interfaces, the gating
interface and the golden traces. Three languages read it: Ruby in the API,
Python in the repository's checks, and Swift on the Mac. Rule AR-002 gives
each fact one home, and the PRD's tables and the contract must be compared
by a check that fails when they differ.

Once the Core loop and the Mac side are built against it, changing the form
of the contract means changing every reader, so the choice is recorded here
(rule AR-003).

## Decision

1. **JSON data files with JSON Schema.** Everything shared lives in
   `api/contract/`, inside the Docker build context, as JSON. Each file's
   shape is a JSON Schema (draft 2020-12) under `api/contract/meta/`, and
   each event type's payload is a schema of its own,
   `payloads/<type>.v<n>.json`. Ruby, Python and Swift read JSON with their
   standard libraries.
2. **OpenAPI 3.1** for the agent, owner and helper HTTP interfaces, in
   `api/contract/openapi.json`. Its schemas are JSON Schema 2020-12 too, so
   one validator checks both.
3. **`json_schemer` 2.5.0** (MIT), in the default group of `api/Gemfile`,
   validates the schemas, the data files, every example and the OpenAPI
   document in the tests, and validates a payload in `Leverage::Contract`.
   It is in the default group because the server will validate each payload
   when it writes an event. It brings `hana` 1.3.7 (MIT) and `simpleidn`
   0.3.0 (MIT); `bigdecimal` and `regexp_parser`, which it also needs, were
   already locked. Ruby's standard library has no JSON Schema validator.
4. **`structure.sql`.** The database schema is `api/db/structure.sql`
   (`config.active_record.schema_format = :sql`), because the schema has
   triggers, constraint triggers and check constraints that `schema.rb`
   cannot hold. Closed values are `text` columns checked by the application
   against the registry, not PostgreSQL enum types.
5. **Two database roles.** Migrations run as the database's owner role.
   `leverage_app`, a `NOLOGIN` role kept by the `db:grants` task, has no
   right to change or remove an event or a rule version; triggers refuse
   those changes for every role as well, though a superuser or the table
   owner can switch the triggers off.
6. **Comparison with the PRD in Python.** `scripts/check_registry.py` and
   `scripts/check_contract_tables.py`, with the standard library only,
   compare the PRD's tables with the registry and the contract files in CI.

## Alternatives considered

- **YAML** for the data files. Easier to write by hand and allows comments,
  but Python's and Swift's standard libraries cannot read it, so every
  reader would need a parser dependency.
- **`schema.rb`.** The Rails default, but it drops the triggers and check
  constraints that hold the PRD's append-only and state-change rules.
- **PostgreSQL enum types** for the closed values. They would put a second
  copy of every list in the database, and adding a value needs a migration.
- **No validator gem**, checking shapes by hand-written Ruby. A second,
  partial implementation of JSON Schema, and the OpenAPI document could not
  be checked against its meta-schema.
- **One role.** Simpler, but then nothing but the application's own care
  keeps the event log unchanged.

## Consequences

- A change to a shared fact is a change to one JSON file, and the tests and
  checks say which other files disagree.
- A payload version, once released, is never edited; a change adds a
  version and every reader handles every listed version.
- The Swift side reads the contract from its own path in tests only. A
  generator for Swift code from the contract is a later choice under
  rule AR-004.
- The API does not yet connect as `leverage_app`; the milestone that first
  writes events switches its login to a member of that role.
