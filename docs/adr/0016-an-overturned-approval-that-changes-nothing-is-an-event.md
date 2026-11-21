# 0016. An overturned approval that changes nothing is an event

Status: Accepted

## Context

The PRD requires a durable record when the owner overturns an approval
for an outward action already done. Stored command outcomes expire.
The record must identify the action, who objected and when (AP-13).

## Decision

Write `action.overturn_recorded` v1 once for that approval, with the
owner as actor, the action as subject and an empty payload. A retry with
the same key returns the stored outcome. A repeat with a new key is
refused as `invalid_state`. The event does not change the task or
action projection. The event log supplies the record to Activity and
Decided for you.

An overturn while the action remains open uses `action.stopped` with
`overturned: true`, the distinction recorded in DB-51.

## Alternatives considered

- Store the actor and time in two columns on `actions`. This needs less
  event-contract work, but would put the record outside the log.
- Use the stored command row. Its retention is shorter than the audit
  record's.

## Consequences

The event type is in both the registry and the PRD's Event types table.
Replay leaves the task and action state as recorded by earlier events.
The owner can record an objection once to the latest approval of a
completed action on a Finishing or Done task. The completed
outward action cannot be undone through leverage.
