# 0015. One method decides what a Finishing task does next

Status: Accepted

## Context

Review pass requests the task's outward actions. Gates, approval jobs,
owner choices, and loss of a builder can change what the task can do
next. Those paths share the same task, action order, original builder
and event log (AE-1, AE-2, AP-15, AP-19).

## Decision

- `Actions` owns the action state changes and their events. Entries
  check the contract's guards and invoke the writers. `CheckReentry`
  routes a settled gate to its pending transition or requested action.
- `Finishing.settle` decides what follows a change to the action
  decisions. It completes the task once all actions are done or waived.
  If work remains after approvals are complete, an enabled,
  unremoved builder can keep the lease or get one when free.
  Otherwise Unconfirmed action opens for the remaining work, even
  when the task still names the previous holder.
- `Finishing.after_command` checks waiting tasks after a command or
  timer. It grants the lease only to the previous builder, with eligible
  tasks ordered by the completing approval or waiver and then task ID.
  At most five grants are made in one pass. An immediate grant can be
  recorded on the deciding event. A delayed grant uses
  `action.lease_granted`.

## Alternatives considered

- Decide separately in each action and hold entry. Each path would have
  to reproduce the same task-wide decision.
- Scan only in the entries that normally release a builder. Credential
  recovery can also make a builder eligible.
- Let the owner approve any stopped action. The owner approval path
  answers a waiting approval. A gate-stopped action has a separate
  check override, subject to the other frozen gates.

## Consequences

- A seat newly eligible for both an approved action and a claim takes
  the action first. A started action is not given to another seat.
- Replay and the log audit follow the same action and lease events.
  The engine tests cover expiry, removal, rework and delayed grants.
