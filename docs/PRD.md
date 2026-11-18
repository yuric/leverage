# leverage — Product Requirements Document

| | |
|---|---|
| **Status** | Draft — requirements not yet written |
| **Owner** | Yuri ([@yuric](https://github.com/yuric)) |
| **Last updated** | 2026-11-18 |

This document is the source of truth for what leverage is and what it must do.
Architecture ([ARCHITECTURE.md](ARCHITECTURE.md)), deployment
([DEPLOY.md](DEPLOY.md)), and all implementation work derive from it. If the
code and this document disagree, one of them has a bug: fix it or change the
requirement here, in a reviewed pull request.

Sections marked _TBD_ are intentionally empty. Do not infer their contents.

## 1. Summary

_TBD — one paragraph: what leverage is, who it is for, and why it should exist._

## 2. Problem

_TBD — the problem being solved, who has it, and how they cope today._

## 3. Goals

_TBD — the outcomes this project commits to. Each goal should be checkable._

## 4. Non-goals

_TBD — what leverage deliberately does not do. As important as the goals._

## 5. Users and use cases

_TBD — the people (or systems) that use leverage and what they are trying to
get done._

## 6. Functional requirements

Each requirement gets a stable ID so issues, pull requests, tests, and commits
can refer to it. IDs are never reused; a removed requirement is marked
_Withdrawn_, not deleted.

| ID | Requirement | Priority | Status |
|----|-------------|----------|--------|
| FR-001 | _TBD_ | | |

**Priority:** `Must` (the release is not viable without it), `Should`
(important, not blocking), `Could` (wanted if cheap).
**Status:** `Proposed`, `Accepted`, `Implemented`, `Withdrawn`.

Every accepted requirement needs acceptance criteria: the observable behavior
that proves it is met.

## 7. Non-functional requirements

| ID | Area | Requirement | Status |
|----|------|-------------|--------|
| NFR-001 | _TBD_ | _TBD_ | |

Areas to consider: security and privacy, performance, reliability,
accessibility, compatibility, observability, cost.

## 8. Constraints and assumptions

_TBD — fixed decisions (platforms, languages, licenses, budgets) and the
assumptions the requirements rest on._

Already decided:

- The project is open source under the [MIT License](../LICENSE).
- Development happens in the open in this repository.

## 9. Success metrics

_TBD — how we will know leverage is working for its users._

## 10. Milestones

_TBD — the order in which requirements ship._

## 11. Open questions

_TBD — unresolved decisions, each with an owner._

## 12. Decision log

Material changes to the requirements are recorded here, newest first.

| Date | Decision | Reason |
|------|----------|--------|
| 2026-11-18 | Repository created; PRD structure established. | Requirements are written before code. |
