# Architecture

| | |
|---|---|
| **Status** | Rules in force; design not started — waiting on requirements in [PRD.md](PRD.md) |
| **Last updated** | 2026-11-18 |

This document describes how leverage is built: its components, how they
communicate, where data lives, and why the design is the way it is. It
describes the system **as it exists**, not as it is hoped to be. Planned work
belongs in the PRD or in issues.

No design has been decided yet: the design sections below are not commitments
until their _TBD_ markers are replaced. The [rules](#rules) are in force now.

## Rules

These rules apply to every change, whoever or whatever writes it. Each rule
has a stable ID that is never reused. A pull request answers every **Active**
rule. A **Pending** rule is agreed but waits for the condition shown.

| ID | Rule | Status |
|----|------|--------|
| AR-001 | [Requirement-scoped pull requests](#ar-001-requirement-scoped-pull-requests) | Active |
| AR-002 | [One authoritative home per fact](#ar-002-one-authoritative-home-per-fact) | Active |
| AR-003 | [Decision record for hard-to-reverse choices](#ar-003-decision-record-for-hard-to-reverse-choices) | Active |
| AR-004 | [Declared, pinned, justified dependencies](#ar-004-declared-pinned-justified-dependencies) | Active |
| AR-005 | [Declared dependency direction](#ar-005-declared-dependency-direction) | Pending: a second code component exists |
| AR-006 | [One mechanism per cross-cutting concern](#ar-006-one-mechanism-per-cross-cutting-concern) | Pending: the first product code lands |
| AR-007 | [Tests that fail before the change, never weakened](#ar-007-tests-that-fail-before-the-change-never-weakened) | Pending: the first product code lands |

### How the rules are applied

1. **Read them before changing anything.** [AGENTS.md](../AGENTS.md) sends
   every agent here first.
2. **Answer them in the pull request.** The description has an "Architecture
   rules" section with one line per active rule, in one of three forms:

   ```text
   - AR-001: Complies
   - AR-003: N/A — no technology or boundary is chosen or changed
   - AR-004: Deviates — docs/adr/0002-short-title.md
   ```

   `N/A` needs a reason. `Deviates` needs an ADR, in the same pull request or
   already merged, that records why the rule is broken.
3. **A required check verifies the answers.** `scripts/check_rules.py` runs as
   the "Rules compliance" check. It fails while any active rule is unanswered,
   and it runs the mechanical part of each rule, listed under the rule. It
   takes the rule list from the base branch as well as from the pull request,
   so a pull request cannot drop a rule to avoid answering it.
4. **Review judges what the check cannot.** The check proves that each rule
   was answered, not that the answer is true. A pull request can also change
   the check itself, and that shows in its diff. The maintainer reads the
   answers at merge.

Dependabot pull requests are exempt from the "Architecture rules" section,
because Dependabot cannot fill it in. The mechanical checks still run on them.

To add, change, activate, or retire a rule, change this section in a pull
request. A pull request that activates a rule adds its line to the
[pull request template](../.github/PULL_REQUEST_TEMPLATE.md); the check fails
if the two lists differ.

### AR-001 Requirement-scoped pull requests

Every pull request names what it implements, either requirement IDs from the
[PRD](PRD.md) or an issue, and changes only what that requires. Unrequested
features, abstractions with a single use, speculative configuration, and
unrelated edits are left out and filed as issues. A small change with neither
a requirement nor an issue behind it (a typo fix, for example) marks this rule
`N/A` and gives its single purpose as the reason.

- **Checked automatically:** when the answer is `Complies`, the description
  cites at least one requirement ID that the PRD defines, or an issue or pull
  request number. Whether that number exists is not checked.
- **Left to review:** whether the change contains only what was required.

### AR-002 One authoritative home per fact

A requirement lives in the [PRD](PRD.md), a decision in its
[ADR](#architecture-decision-records), a rule in this section, and an
interface definition in this document. Other files and pull requests refer to
them by ID or link and do not restate them. A generated file is changed only
by changing its source and regenerating it.

- **Checked automatically:** every `FR-`, `NFR-`, and `AR-` ID used in a pull
  request description or in `docs/` is defined in its home, and every `AR-` ID
  used in any Markdown file is defined here. `docs/research/` is left out
  because it is an archive, and files outside `docs/` use requirement IDs only
  as format examples.
- **Left to review:** whether prose restates a fact that already has a home.
  Regenerating generated files in CI waits for the first generator.

### AR-003 Decision record for hard-to-reverse choices

A pull request that chooses or changes a language, runtime, framework,
datastore, external service, or component boundary adds an ADR in `docs/adr/`
with status `Proposed` or `Accepted`. A pull request that contradicts an
accepted ADR either supersedes it in the same pull request or stops and asks.
The format is under
[Architecture decision records](#architecture-decision-records).

- **Checked automatically:** every ADR has a valid file name, a unique number,
  and a valid status, and a superseded ADR names a successor that exists. A
  pull request that adds a dependency manifest (`package.json`, `go.mod`,
  `pyproject.toml`, and the like) or changes the
  [Components](#components) or [Technology choices](#technology-choices)
  section must also add or change an ADR. Answering `N/A` with a reason turns
  that failure into a warning, for changes such as a typo fix.
- **Left to review:** whether a choice is hard to reverse, and whether a
  change contradicts an accepted ADR.

### AR-004 Declared, pinned, justified dependencies

A pull request that adds a dependency (a library, tool, GitHub Action, or
external service) names each one in its description with its license, its
pinned version or commit SHA, and why existing code or the standard library
does not suffice. The dependency must exist in its official registry, and its
license must be compatible with the MIT License.

- **Checked automatically:** every action used in `.github/workflows/` is
  pinned to a full commit SHA, and an action that the base branch does not
  already use is named in the description.
- **Left to review:** the license, the justification, and whether the package
  is the real one. Checking library manifests waits for the first manifest.

### AR-005 Declared dependency direction

Code imports only along the dependency directions listed under
[Components](#components). A pull request that needs a new direction changes
that list, with an ADR, in the same pull request.

- **Pending:** the list and an import check in CI are added when a second code
  component exists.

### AR-006 One mechanism per cross-cutting concern

Each cross-cutting concern (errors, logging, configuration, persistence,
shared helpers) has one designated mechanism, named in this document. A pull
request uses it and does not add a second mechanism or a duplicate of
something it already provides.

- **Pending:** the mechanisms are named when the first product code lands.

### AR-007 Tests that fail before the change, never weakened

A pull request that changes behavior adds or updates at least one test that
fails on the base branch and passes with the change. It does not delete,
skip, or loosen an existing assertion unless its description names the
assertion and the reason.

- **Pending:** applies, with a CI check, when the first product code lands.

## System overview

_TBD — one diagram and one paragraph: the major components and how a request
or job flows through them._

## Components

_TBD — for each component: its responsibility, what it owns, what it depends
on, and where its code lives._

## Data

_TBD — what is stored, where, who can read and write it, and how long it is
kept._

## Interfaces

_TBD — public APIs, CLIs, file formats, and events, with their stability
guarantees._

## Trust boundaries

_TBD — where untrusted input enters, where privileges change, and what each
boundary enforces. Security review starts here; see
[SECURITY.md](../SECURITY.md)._

## Technology choices

_TBD — languages, frameworks, and infrastructure, each with the reason it was
chosen._

## Architecture decision records

Significant, hard-to-reverse decisions are recorded as short ADRs in
`docs/adr/`, numbered in order (`0001-short-title.md`). Rule
[AR-003](#ar-003-decision-record-for-hard-to-reverse-choices) says when one is
required. Each ADR follows this outline and stays short:

```markdown
# 0001. Short title

Status: Proposed

## Context

## Decision

## Alternatives considered

## Consequences
```

The status is one of `Proposed`, `Accepted`, `Rejected`, or
`Superseded by 0002` (the number of the ADR that replaces it). Only an
accepted ADR is binding. Once an ADR is accepted, only its status line
changes; a later ADR supersedes it.

No ADRs have been recorded yet.
