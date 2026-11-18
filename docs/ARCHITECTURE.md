# Architecture

| | |
|---|---|
| **Status** | Not started — waiting on requirements in [PRD.md](PRD.md) |
| **Last updated** | 2026-11-18 |

This document describes how leverage is built: its components, how they
communicate, where data lives, and why the design is the way it is. It
describes the system **as it exists**, not as it is hoped to be. Planned work
belongs in the PRD or in issues.

No architecture has been decided yet. Nothing below is a commitment until the
_TBD_ markers are replaced.

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
`docs/adr/`, numbered in order (`0001-short-title.md`). Each one states the
context, the decision, the alternatives considered, and the consequences. An
ADR is never edited after it is accepted; a later ADR supersedes it.

No ADRs have been recorded yet.
