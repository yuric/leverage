# 0008. How a run moves to another account

Status: Accepted

## Context

The Handoff milestone continues a task or a review on the next account in
the Handoff order when the account a run is on reaches a limit or is found
signed out (PRD, Handoff). The pieces already exist and must not be undone:
the server decides everything and writes the log; the helper starts and
stops one `LeverageRunner` per seat the app runs, with the seat's token in
the runner's environment only ([ADR 0005](0005-code-units-of-the-core-loop.md));
and the runner and the helper never import each other. Only the runner sees
what a provider's tool prints, and a tool's output can hold the account's
email and plan. Which account each claim and each review ran on is a
record the provider rule of the Rule checks milestone will be checked
against, so it must be complete from now on. How the account moves between
the three programs is hard to change once the log holds runs that moved
this way (rule AR-003). The decisions are the milestone's plan HD-1 to
HD-6, HD-9 and HD-10.

## Decision

1. **A run is on one account for its whole life.** `seats.run_credential_id`
   is the credential the seat's current token was issued for:
   `issue_seat_token` copies it from the `start_seat` request the helper
   picked up, and a stopped run or an interruption clears it;
   `seats.run_stop_reason` keeps why the last run ended (HD-3).
2. **The server asks for the run it needs.** Whenever the server records
   work on a credential the seat's run is not on, or the seat has no run,
   `SeatRuns.ensure_run_on` queues one `start_seat` helper request naming
   that credential, and in `params` the role, provider, model and effort
   that apply and the `task_id` or `review_id` to continue. It queues
   nothing while an unfinished start for the seat exists or the owner does
   not want the seat running. The commands that do this are an
   interruption report that switches, the close of a credential hold, and
   a failed review whose fresh lease starts on another account; the
   helper-token reconciliation, Start and Connect build their requests from
   the same `SeatRuns.placement` (HD-1).
3. **A claim records the account that does the work.** A seat the app runs
   may claim a task or a review only when one of its candidates is
   available for it and its run is on the first of them (`Eligibility`,
   and `GET /v1/next` by the same method). The workspace timer
   `seat_run_placement`, fired by every sweep, moves an idle running seat
   to its first available candidate and starts again a seat the owner
   wants running whose last run ended for a limit or a sign-out. A run that
   ended for any other reason is not started again until the app is opened
   (HD-4).
4. **The runner detects; the helper reports.** After a failed tool run of
   a seat that has a credential, the runner's `Interruption` asks the
   provider's detector in LeverageKit and, when the output does not settle
   it, `SignInStatus` ([ADR 0009](0009-detectors-from-recorded-and-made-replies.md)).
   On a limit or a sign-out the runner stops its heartbeat, gives back
   nothing, prints one line of JSON (`RunEndReport`: kind, window, reset
   time, the task or review id, the tool's version, the time) on standard
   output and exits with code 5. No word of the tool's reply is in that
   line, and nothing is written to disk (HD-5, HD-6).
5. **The helper turns that line into one report.** The helper sends only
   standard error of a runner to the seat's log, reads the last line of
   standard output on code 5, and sends `report_limit` or
   `report_signed_out` with the run's seat and credential, retrying with
   the same key on a transport failure. If the report is refused it sends
   `report_run_stopped` with the reason `limit` or `signed_out`. Code 5
   with no readable line is handled as code 4 (HD-6, HD-10).
6. **A hand-over replaces a live run without a release.** A `start_seat`
   for a seat whose run is alive first asks for the new seat token, which
   ends the old run's token, then stops the old run, then starts the new
   one. The old run's release is answered `401`, so it gives nothing back,
   and a run ended by a hand-over sends no report (HD-2, HD-10).
7. **A continuing run starts from the work it was given.** With
   `LEVERAGE_CONTINUE_TASK_ID` or `LEVERAGE_CONTINUE_REVIEW_ID` set, the
   runner reads that work's briefing and goes on from its first criterion
   that has not passed, announcing it again; it acknowledges the briefing
   only when a call is refused for want of one. No session of the earlier
   run is resumed (HD-9).

## Alternatives considered

- **The helper runs the tool and reads its output.** It would undo the
  split between the helper and the runner and put a second reader of the
  tool's output beside the runner's.
- **Let a claim land on any available account and move the run
  afterwards.** Simpler, but a few seconds of work would be done on an
  account the record does not name.
- **A third pipe, or a file, from the runner to the helper.** Standard
  output was free: the runner printed nothing there but its version.
- **Stop the old run before asking for the new token** (milestone 2's
  order). The old run's release would then reach the server and give back
  the work the new run is meant to continue.

## Consequences

- Up to one sweep interval (15 seconds) may pass before an idle agent
  changes account, and a credential hold that becomes due by the clock is
  closed at the next sweep.
- Every claim, review start and switch names its credential, so the set of
  providers that built a task can be read back from `task.claimed`,
  `review.started` and `credential.switched` (`provider_record_test.rb`).
- A run that meets a limit the detectors do not recognise is still
  milestone 2's failing run: three in a row end it with code 4, and it is
  not started again until the app is opened.
- A seat that connects on its own has no credential known to Leverage, so
  nothing is detected for it.
