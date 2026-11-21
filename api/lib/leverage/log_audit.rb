require "set"

module Leverage
  # The log audit (PRD L896: each command wrote the events the lifecycle
  # table names for it, plus only the side events the PRD requires; L895:
  # the steps partition each task's life; milestone 2 plan §2.1). It reads
  # a workspace's log and lists every disagreement as a line; an empty list
  # means the log passes.
  #
  # Commands. The workspace lock gives each command its own at. Keyed
  # events group by command_id and at, and keyless events form consecutive
  # runs at that time. A group with a key is the
  # command of the commands row with that key (by the caller its actor
  # names when several callers used one key; when the row is gone, purged
  # after 7 days, every command whose rows write the group's first event is
  # tried). A group with no key is app-written: task.lease_expired is
  # builder_lease_expiry, review.lease_expired review_lease_expiry, and a
  # hold.closed of a credential hold (credential_limit or
  # credential_signed_out) with neither is credential_hold_release
  # (milestone 3 plan §2.1 rule 8), one group per task. One command may
  # apply several timers of one task (Timers.apply_task_timers: the
  # credential hold when it is due first, then the lease), so a task's
  # events are cut before each lease end, and each run is matched to its
  # own timer. Any other event with no key is a finding.
  #
  # For each group, the task's state before it is folded from the log, and
  # the command's state_machine.json rows from that state are matched as
  # milestone 1's traces test matches a trace: a row fits when every event
  # it names was written; the events must all belong to the fitting rows
  # (their events, conditional events and side events) or be side events
  # the registry marks written_as_side_event; and the state the events lead
  # to must be a fitting row's. A row with no state (a seat command whose
  # conditional event releases a task) is not held to a state. A refused
  # command writes no event of its own: only rule check, hold and Needs you
  # events.
  #
  # credential.switched is marked written_as_side_event, but the PRD (L896)
  # allows it only beside the rows that name it (milestone 3 plan §2.3): a
  # report that hands over at once, a credential hold's close, a fresh
  # lease on another account. So it must belong to a fitting row.
  # A command whose rows have no state (report_request_result, change_seat:
  # a verified login may close the credential holds of several tasks) may
  # touch several tasks. Any other touches its own task (its first event's),
  # and beside it only the side events a row writes on another task: the
  # "Account signed out" item a sign-out opens on another task's
  # credential_limit hold (HE-11, OTHER_TASK), and the provider rule's
  # applied rows review claim-next writes on the tasks of the reviews it
  # skips (RC-50, RD-12; OTHER_TASK_OF).
  #
  # Milestone 4 (its plan RE-3, RT-4):
  #
  # A command that waits on a model check (a pending transition with its
  # key) writes, when it is sent, only rule check, job, hold and Needs you
  # events; its own row's events come later, under its key, in whichever
  # command or timer brings the last result (RE-3), and are matched then
  # as the waiting command's rows from the task's state. Events under a
  # key at another time than the command's own are allowed only when a
  # pending transition of that key exists. A job result whose Complete
  # contract waits (RE-6) is matched as the job result. A gate that fails
  # at a hook whose failed gate is hold_contract_incomplete reads as the
  # gated row with the contract change and the hold, and its from-state as
  # its to-state (rule 7, RD-10), as the traces' test reads it.
  #
  # Events with no key also come from the job timers (job.timed_out), from
  # the workspace timers orchestrator_offline and reviewer_eligibility
  # (their Needs you items name them) and from the one-time write of the
  # shipped rules (rule.created). Several timers on one task can have
  # the same effective time when their due times precede its latest event.
  #
  # The gate (RT-4, test 4): no task.ready, task.claimed, task.submitted or
  # review.passed is written by a command that had, at its hook, an
  # enabled blocking gate in its frozen set (the pending transition's, or
  # the rules on at that point of the log; a frozen rule turned off or
  # removed before the move is not enabled) without a rule check row of
  # that version, hook, round and subject that passed, did not apply, was
  # withdrawn or was overridden.
  #
  # Steps. Each task's rows, in the order they opened: the first opens at
  # task.created, each closes where the next opens (the same time, in the
  # same command), at most one is open,
  # none after task.done or task.cancelled (where the last closes), none is
  # negative, and they sum to the task's lifetime. A task's effective
  # times never go backwards (L120).
  module LogAudit
    TIMER_EVENTS = { "task.lease_expired" => "builder_lease_expiry", "review.lease_expired" => "review_lease_expiry" }.freeze
    CREDENTIAL_HOLD_RELEASE = "credential_hold_release".freeze
    CREDENTIAL_HOLDS = %w[credential_limit credential_signed_out].freeze
    ROW_ONLY = %w[credential.switched].freeze
    OTHER_TASK = %w[inbox.opened].freeze
    # A command's events on other tasks than its own, by command: review
    # claim-next records the provider rule's applied row for each review it
    # skips, on that review's task (RC-50, RD-12).
    OTHER_TASK_OF = { "claim_review" => %w[check.finished] }.freeze
    TERMINAL = %w[task.done task.cancelled].freeze
    REFUSED_MAY_WRITE = /\A(check|hold|inbox|job)\./
    # What a command writes when it is sent and then waits (RE-3).
    WAITING_MAY_WRITE = REFUSED_MAY_WRITE
    JOB_TIMERS = %w[
      check_queue_timeout check_run_timeout contract_draft_job_queue_timeout contract_draft_job_run_timeout
      question_job_queue_timeout question_job_run_timeout
    ].freeze
    # The workspace timers and the one-time write, by what their events name.
    ITEM_TIMERS = { "orchestrator_offline" => "orchestrator_offline", "no_reviewer_eligible" => "reviewer_eligibility" }.freeze
    INSTALL = "install_shipped_rules".freeze
    # The withdrawals a timer that ends a waiting command writes before its
    # lease end (rule 11).
    CANCEL_EVENTS = %w[check.finished job.withdrawn hold.closed inbox.resolved].freeze
    # The moves a gate guards (RT-4), the command that writes each, and its hook.
    GATED = { "complete_contract" => [ "task.ready", "task.before_ready" ], "claim" => [ "task.claimed", "task.before_claim" ],
              "submit" => [ "task.submitted", "task.before_submit" ], "pass_review" => [ "review.passed", "task.before_done" ] }.freeze
    CLEARED = %w[passed not_applicable withdrawn].freeze
    ACTION_HOOK = "action.requested".freeze
    ACTION_WORK = %w[action.started action.reported_done].freeze
    ACTION_COMPLETE = %w[done waived].freeze
    # A command that runs another entry as its requester inside it (RE-6:
    # a planner's draft result is Complete contract): its events are its
    # own row's and, on the task, the other entry's.
    RUN_AS = { "submit_job_result" => "complete_contract" }.freeze
    OWN_ONLY = %w[job. cost.reported].freeze
    ACTION_RESULTS = { "action.approved" => "approve_action", "action.stopped" => "stop_action" }.freeze
    LEASE_FIELD = "lease_seat_id".freeze

    Group = Data.define(:command_id, :at, :events)

    module_function

    # Every finding for the workspace, as lines. after_seq: audit only the
    # commands after it (the log before it is still folded for the tasks'
    # states), for a log whose start was built by a test's Scenario.
    def call(workspace_id, after_seq: 0)
      audit = { states: {}, rounds: Hash.new(0), rules: {}, seen: Set.new }
      states = audit.fetch(:states)
      findings = []
      groups(workspace_id).each do |group|
        if group.events.first.seq > after_seq
          findings.concat(audit_group(workspace_id, group, states, audit))
        else
          group.events.each { |event| states[event.task_id] = observe(states[event.task_id], [ event ]) if event.task_id }
        end
        note(group, audit)
      end
      findings + action_findings(workspace_id, after_seq) + step_findings(workspace_id, after_seq) + time_findings(workspace_id, after_seq)
    end

    # --- commands --------------------------------------------------------------

    # Keyed events belong to one command at one time, even when a pending
    # command completes under its own key between two of them (RE-3).
    # Keyless events share no such identity: a command can run a due timer
    # and later request actions after a keyed pass_review. Keep those
    # keyless runs on their own side of the task's move to Finishing.
    def groups(workspace_id)
      ordered = []
      keyed = {}
      keyless = nil
      Replay.each_event(workspace_id) do |event|
        if event.command_id
          keyless = nil
          group = keyed[[ event.command_id, event.at ]] ||= append_group(ordered, event)
        else
          keyless = append_group(ordered, event) unless keyless&.at == event.at
          group = keyless
        end
        group.events << event
      end
      ordered
    end

    def append_group(groups, event)
      Group.new(command_id: event.command_id, at: event.at, events: []).tap { |group| groups << group }
    end

    def audit_group(workspace_id, group, states, audit)
      row = command_row(workspace_id, group) if group.command_id
      label = "command #{group.command_id} (seq #{group.events.first.seq})"
      grants, events = separate_lease_grants(group.events) unless row&.command == "grant_action_lease"
      if grants.present?
        group = Group.new(command_id: group.command_id, at: group.at, events: events)
      end

      findings = if group.events.empty?
        []
      elsif group.command_id.nil?
        timer_groups(group, states)
      else
        pending = waiting(workspace_id, group.command_id, row)
        command_findings(group, row, pending, states, audit, label)
      end
      Array(grants).each do |grant|
        findings.concat(named(label, [ "grant_action_lease" ], grant, states))
      end
      findings
    end

    # Finishing may grant an approved action a lease after a command,
    # even on another task or when the command was refused.
    def separate_lease_grants(events)
      leases = events.select { |event| event.type == "action.lease_granted" }.to_h { |event| [ event.id, [ event ] ] }
      return [ [], events ] if leases.empty?

      own = events.reject do |event|
        next true if leases.key?(event.id)
        next false unless event.type == "credential.switched" && leases.key?(event.cause_id)

        leases.fetch(event.cause_id) << event
        true
      end
      [ leases.values, own ]
    end

    def command_findings(group, row, pending, states, audit, label)
      first = audit.fetch(:seen).add?([ group.command_id, row&.id ])
      findings = gate_findings(group, row, pending, audit, label)
      return findings + completion(group, pending, states, label) if pending && !first
      return findings + later_without_pending(group, row, states, label) if !first && row&.outcome != "refused"

      ran_now = pending && row && row.command != pending.command
      if (row&.outcome == "refused" && !ran_now) || (pending && row && row.command == pending.command)
        allowed = row&.outcome == "refused" ? REFUSED_MAY_WRITE : WAITING_MAY_WRITE
        own = group.events.map(&:type).grep_v(allowed)
        advance(group.events, states)
        verb = row&.outcome == "refused" ? "was refused" : "waited"
        return findings if own.empty?

        return findings + [ "#{label}: #{row&.command || pending.command} #{verb} but wrote #{own.uniq.join(", ")}" ]
      end
      names = row ? [ row.command ] : candidates(group.events.first.type)
      findings + named(label, names, group.events, states)
    end

    def named(label, names, events, states)
      problems = names.map { |name| match(name, events, states) }
      if names.include?("submit_job_result") && events.any? { |event| event.type == "job.finished" }
        action = events.find { |event| ACTION_RESULTS.key?(event.type) }
        if action
          theirs, mine = events.partition { |event| event == action || event.cause_id == action.id }
          theirs.concat(mine.select { |event| %w[hold.opened inbox.opened].include?(event.type) && event.task_id == action.task_id })
          problems << match("submit_job_result", mine, states) + match(ACTION_RESULTS.fetch(action.type), theirs, states)
        end
      end
      names.filter_map { |name| RUN_AS[name] && [ name, RUN_AS[name] ] }.each do |own, other|
        mine, theirs = events.partition { |event| event.type.start_with?(*OWN_ONLY) }
        next if theirs.empty?

        problems << match(own, mine, states) + match(other, theirs, states)
      end
      advance(events, states)
      best = problems.min_by(&:size)
      best.empty? ? [] : [ "#{label}: #{names.join(" or ")} #{best.join("; ")}" ]
    end

    # The pending transition a command's key stored, if it ever waited.
    def waiting(workspace_id, key, row)
      return unless row

      PendingTransition.where(workspace_id: workspace_id, command_key: key).order(:created_at).first
    end

    # A waiting command's own events, written later under its key (RE-3):
    # its rows from the task's state, with the gate's events beside them.
    def completion(group, pending, states, label)
      named(label, [ pending.command ], group.events, states)
    end

    # Events under a key at another time than its command's own, with no
    # pending transition of that key (RE-3 allows none).
    def later_without_pending(group, row, states, label)
      advance(group.events, states)
      [ "#{label}: #{row&.command || "a command"} wrote #{group.events.map(&:type).uniq.join(", ")} under its key " \
        "at another time than its own, though it never waited (RE-3)" ]
    end

    def timer_groups(group, states)
      name = workspace_timer(group.events)
      return named("events with no command (seq #{group.events.first.seq})", [ name ], group.events, states) if name

      group.events.group_by(&:task_id).flat_map do |task_id, task_events|
        timer_runs(task_events).flat_map { |events| timer_run(task_id, events, states) }
      end
    end

    # The workspace timer or the one-time write a group of events with no
    # key belongs to, by what they name, or nil. A group with a lease end
    # is task timers': the "No reviewer is eligible" item beside a
    # review.lease_expired is that timer's side event (SM-42), and a
    # command applies no workspace timer.
    def workspace_timer(events)
      return INSTALL if events.any? { |event| event.type == "rule.created" }
      return if events.any? { |event| TIMER_EVENTS.key?(event.type) }

      kinds = events.select { |event| event.type.start_with?("inbox.") }.filter_map do |event|
        event.type == "inbox.opened" ? (event.payload || {})["kind"] : InboxItem.find_by(id: event.subject_id)&.kind
      end
      kinds.filter_map { |kind| ITEM_TIMERS[kind] }.first
    end

    # A job timeout always starts its timer. When the task's last effective
    # time clamps two due times together, a credential hold close can start
    # the next timer in that same instant. A lease expiry can close a seat's
    # credential hold itself, so leave those closes with the lease.
    def timer_runs(events)
      runs = []
      events.each do |event|
        run = runs.last
        if !run || event.effective_at != run.last.effective_at || event.type == "job.timed_out" ||
            (run.first.type == "job.timed_out" && credential_close?(event)) ||
            (TIMER_EVENTS.key?(event.type) && !CANCEL_EVENTS.include?(run.last.type))
          runs << []
        end
        runs.last << event
      end
      runs
    end

    def timer_run(task_id, events, states)
      types = events.map(&:type)
      names = timer_names(events)
      label = "events with no command (seq #{events.first.seq}, #{types.uniq.join(", ")})"
      problems = names.empty? ? [ "no timer writes them" ] : names.map { |name| match(name, events, states) }.min_by(&:size)
      advance(events, states) if task_id
      problems.empty? ? [] : [ "#{label}: #{names.join(" or ").presence || "no command"} #{problems.join("; ")}" ]
    end

    def timer_names(events)
      types = events.map(&:type)
      lease = types.filter_map { |type| TIMER_EVENTS[type] }.first
      return [ lease ] if lease
      return JOB_TIMERS if types.include?("job.timed_out")
      return [ "grant_action_lease" ] if types.include?("action.lease_granted")
      return [ "orchestrator_offline" ] if events.any? { |event| recovered_claim_hold?(event) }
      return [ "request_action" ] if events.any? { |event| action_request_event?(event) }

      [ credential_release(events) ].compact
    end

    # The orchestrator may return before its offline item was opened. Its
    # only timer event can be the close of an errored claim's check_error
    # hold (RC-37). Use the check's history, since the next claim may have
    # changed its result by the time the log is audited.
    def recovered_claim_hold?(event)
      return false unless event.type == "hold.closed" && event.actor_kind == "app" && event.payload["reason"] == "check_error"

      earlier = Event.where(workspace_id: event.workspace_id, task_id: event.task_id).where("seq < ?", event.seq)
      opened = earlier.where(subject_kind: "hold", subject_id: event.subject_id, type: %w[hold.opened hold.closed]).order(:seq).last
      return false unless opened&.type == "hold.opened" && opened.payload["reason"] == "check_error"

      check_id = opened.payload["rule_check_id"]
      return false unless check_id

      check = earlier.where(subject_kind: "rule_check", subject_id: check_id, type: %w[check.queued check.finished check.overridden])
        .order(:seq).last
      check&.type == "check.finished" && check.payload.values_at("hook", "result") == %w[task.before_claim error]
    end

    def action_request_event?(event)
      case event.type
      when "check.queued", "check.finished" then event.payload["hook"] == ACTION_HOOK
      when "hold.opened" then event.payload["reason"] == "owner_approval"
      else false
      end
    end

    # credential_hold_release when the events close a credential hold.
    def credential_release(events)
      closes = events.select { |event| event.type == "hold.closed" }
      return unless closes.any? && closes.all? { |event| credential_close?(event) }

      switches = events.select { |event| event.type == "credential.switched" }
      return unless switches.all? { |event| closes.any? { |close| close.id == event.cause_id && close.seq < event.seq } }

      CREDENTIAL_HOLD_RELEASE
    end

    def credential_close?(event)
      event.type == "hold.closed" && CREDENTIAL_HOLDS.include?(event.payload["reason"])
    end

    # The commands row a group of events belongs to.
    def command_row(workspace_id, group)
      rows = Command.where(workspace_id: workspace_id, key: group.command_id).to_a
      return rows.first if rows.size <= 1

      actors = group.events.map { |event| [ event.actor_kind, event.actor_id ] }
      rows.find do |row|
        actors.any? do |kind, id|
          id == row.caller_id && (kind == row.caller_kind || (kind == "app" && row.caller_kind == "helper"))
        end
      end || rows.first
    end

    # Every command whose rows write this event.
    def candidates(type)
      all_rows.select { |row| row.fetch("events").include?(type) || extra_events(row).include?(type) }
        .map { |row| row.fetch("command") }.uniq
    end

    # What is wrong with these events as one command of this name, from the
    # state their task was in; empty when a row fits.
    def match(name, events, states)
      tasks = events.filter_map(&:task_id).uniq
      named = rows_of(name)
      stateless = named.any? && named.none? { |row| row.fetch("from") || row.fetch("to") }
      others = []
      if tasks.size > 1 && !stateless
        allowed = OTHER_TASK + OTHER_TASK_OF.fetch(name, [])
        # The command's own task is that of its first event that is not one
        # it may write on another task.
        own = (events.find { |event| event.task_id && !allowed.include?(event.type) } || events.first).task_id
        others = events.select { |event| event.task_id && event.task_id != own }
        unless others.all? { |event| allowed.include?(event.type) || cross_task_side_event?(event, events) }
          return [ "touches #{tasks.size} tasks" ]
        end

        events -= others
        tasks = [ own ]
      end

      task = tasks.first unless tasks.size > 1
      state = task && states[task]
      types = events.map(&:type)
      # Reorder can write for several credentials. Remove has one target.
      if types.count("credential.removed") > 1
        return [ "wrote credential.removed more than once" ]
      end

      fresh = events.any? { |event| (event.payload || {})[LEASE_FIELD] }
      observed = task ? observe(state, events) : nil
      rows = named.select { |row| row.fetch("from").nil? || row.fetch("from") == state }
      kept = pick(rows, types, fresh, observed)
      return [ "has no row from #{state.inspect} that writes #{types.join(", ")}" ] if kept.empty?

      allowed = kept.flat_map { |row| row.fetch("events") + extra_events(row) }.to_set
      stray = (events + others).reject do |event|
        allowed.include?(event.type) || side_types.include?(event.type) || action_override?(name, event, events)
      end
      problems = []
      problems << "wrote #{stray.map(&:type).uniq.join(", ")}, which no matched row allows" unless stray.empty?
      stateful = kept.select { |row| row.fetch("from") || row.fetch("to") }
      if task && stateful.any? && stateful.none? { |row| (row.fetch("to") || row.fetch("from")) == observed }
        problems << "led #{task} from #{state.inspect} to #{observed.inspect}, which no matched row allows"
      end
      problems
    end

    # An override can approve a stopped action or reenter an errored
    # action check. If reentry finds another failed gate, the stopped
    # event names that gate's finished check as its cause.
    def action_override?(name, event, events)
      return false unless name == "override_check"

      override = events.find { |candidate| candidate.type == "check.overridden" && candidate.task_id == event.task_id }
      return false unless override && override.seq < event.seq
      return event.cause_id == override.id if event.type == "action.approved"
      return false unless event.type == "action.stopped" && event.actor_kind == "app"

      cause = Event.find_by(id: event.cause_id, workspace_id: event.workspace_id, task_id: event.task_id,
        round: event.round, type: "check.finished")
      cause && cause.seq < event.seq && cause.subject_id != override.subject_id &&
        cause.payload.values_at("hook", "result", "subject_kind", "subject_id") ==
          [ ACTION_HOOK, "failed", "action", event.subject_id ]
    end

    def cross_task_side_event?(event, events)
      event.type == "hold.opened" && event.payload["reason"] == "project_paused" && events.any? do |pause|
        pause.type == "project.paused" && pause.project_id == event.project_id && pause.id == event.cause_id
      end
    end

    # The rows whose events were all written; on a tie, the rows the fresh
    # lease and the state reached pick, then the rows that name the most.
    def pick(rows, types, fresh, observed)
      fit = rows.select { |row| (row.fetch("events") - types).empty? }
      return [] if fit.empty?

      if fit.any? { |row| row.fetch("builder_lease") == "fresh" } && fit.any? { |row| row.fetch("builder_lease") != "fresh" }
        fit = fit.select { |row| (row.fetch("builder_lease") == "fresh") == fresh }
      end
      if fit.any? { |row| row.fetch("from") || row.fetch("to") }
        leads = fit.select { |row| (row.fetch("to") || row.fetch("from")) == observed }
        fit = leads unless leads.empty?
      end
      most = fit.map { |row| row.fetch("events").size }.max
      fit.select { |row| row.fetch("events").size == most }
    end

    def advance(events, states)
      events.group_by(&:task_id).each { |task, group| states[task] = observe(states[task], group) if task }
    end

    # The state a task's events lead to, read from the events alone.
    def observe(state, events)
      events.reduce(state) do |current, event|
        payload = event.payload || {}
        case event.type
        when "task.created" then payload["state"]
        when "task.promoted", "task.returned" then "backlog"
        when "task.ready", "task.reassigned" then "ready"
        when "task.claimed" then "working"
        when "task.submitted" then "in_review"
        when "task.done" then "done"
        when "task.cancelled" then "cancelled"
        when "action.requested" then current == "in_review" ? "finishing" : current
        when "review.failed", "task.returned_for_rework" then payload[LEASE_FIELD] ? "working" : "ready"
        when "task.released", "task.lease_expired" then current == "working" ? "ready" : current
        else current
        end
      end
    end

    def all_rows
      @all_rows ||= Contract.state_machine.fetch("groups").flat_map { |group| group.fetch("rows") }
    end

    # A command's rows that complete, with the row a failed
    # hold_contract_incomplete gate reads as (rule 7, RD-10): the gated
    # row's contract change and the hold, staying in its state; and, where
    # the failed gate is failed_review, fail_review's rows (SM-6: a failed
    # review in full).
    def rows_of(name)
      @rows_of ||= {}
      @rows_of[name] ||= begin
        rows = all_rows.select { |row| row.fetch("command") == name && row.fetch("refusal").nil? }
        failed_review = rows.any? { |row| failed_gates[row.fetch("hook")] == "failed_review" } ? rows_of("fail_review") : []
        failed_action = name == "request_action" ? rows_of("stop_action") : []
        rows + rows.filter_map { |row| failed_gate_row(row) } + failed_review + failed_action
      end
    end

    def failed_gate_row(row)
      return unless failed_gates[row.fetch("hook")] == "hold_contract_incomplete"

      row.merge("events" => (row.fetch("events") & [ "task.contract_changed" ]) + [ "hold.opened" ], "to" => row.fetch("from"))
    end

    def failed_gates
      @failed_gates ||= Contract.hooks.fetch("hooks").to_h { |entry| [ entry.fetch("hook"), entry["failed_gate"] ] }
    end

    # --- the gate (RT-4) ---------------------------------------------------------

    # What a group tells the audit for later groups: rule switches and
    # versions, and each task's round.
    def note(group, audit)
      group.events.each do |event|
        note_rule(event, audit.fetch(:rules))
        audit.fetch(:rounds)[event.task_id] += 1 if %w[review.failed task.returned_for_rework].include?(event.type)
      end
    end

    def note_rule(event, rules)
      payload = event.payload || {}
      case event.type
      when "rule.created" then rules[event.subject_id] = { enabled: payload["enabled"], version_id: payload["rule_version_id"] }
      when "rule.changed", "rule.reverted" then rules.fetch(event.subject_id)[:version_id] = payload["rule_version_id"]
      when "rule.enabled", "rule.disabled" then rules.fetch(event.subject_id)[:enabled] = event.type == "rule.enabled"
      when "rule.removed" then rules.fetch(event.subject_id)[:enabled] = false
      end
    end

    # --- outward actions (AT-4) -------------------------------------------------

    # A command can complete a pending command under a different key between
    # two of its own events. The action audit follows seq, so neither that
    # grouping nor a later check result can clear an earlier approval.
    def action_findings(workspace_id, after_seq)
      events = Event.where(workspace_id: workspace_id)
      return [] unless events.where(type: [ ACTION_HOOK, "action.approved", "task.done", *ACTION_WORK ]).exists?

      ActionAudit.new(workspace_id, after_seq).call
    end

    class ActionAudit
      def initialize(workspace_id, after_seq)
        @workspace_id = workspace_id
        @after_seq = after_seq
        @rules = {}
        @gate_versions = RuleVersion.where(workspace_id: workspace_id, hook: ACTION_HOOK)
          .select { |version| LogAudit.blocking_gate?(version, ACTION_HOOK) }.index_by(&:id)
        @check_ids = RuleCheck.where(workspace_id: workspace_id, hook: ACTION_HOOK).pluck(:id).to_set
        @reviews = Set.new
        @requests = {}
        @approvals = Set.new
        @actions = Hash.new { |tasks, task_id| tasks[task_id] = {} }
        @checks = {}
        @action_checks = Hash.new { |gates, key| gates[key] = [] }
        @findings = []
      end

      def call
        Replay.each_event(@workspace_id) do |event|
          LogAudit.note_rule(event, @rules)
          observe(event) if event.task_id
        end
        @findings
      end

      private

      def observe(event)
        round = [ event.task_id, event.round ]
        action = [ *round, event.subject_id ]
        case event.type
        when "review.passed"
          @reviews << round
        when ACTION_HOOK
          @requests[action] = @rules.values.filter_map { |rule| @gate_versions[rule[:version_id]] if rule[:enabled] }
        when "check.queued", "check.finished"
          note_check(event, round)
        when "check.overridden"
          @checks[event.subject_id][:overridden] = true if @checks.key?(event.subject_id)
        when "action.approved"
          approve(event, round, action)
        when *ACTION_WORK
          finding(event, "has no earlier action.approved for the action in the same round") unless @approvals.include?(action)
        when "task.done"
          open = @actions[event.task_id].reject { |_, row| ACTION_COMPLETE.include?(row.fetch("state")) }
          finding(event, "has unresolved action IDs #{open.keys.join(", ")}") if open.any?
        end
        Replay.project_actions(@actions[event.task_id], event)
      end

      def note_check(event, round)
        payload = event.payload
        return unless payload["hook"] == ACTION_HOOK && payload["subject_kind"] == "action" && @check_ids.include?(event.subject_id)

        key = [ *round, payload["subject_id"], payload["rule_version_id"] ]
        row = @checks[event.subject_id] ||= { overridden: false }
        @action_checks[key] << event.subject_id unless @action_checks[key].include?(event.subject_id)
        row[:result] = payload["result"]
      end

      def approve(event, round, action)
        finding(event, "has no earlier review.passed for the same round") unless @reviews.include?(round)
        frozen = @requests[action]
        finding(event, "has no earlier action.requested for the action in the same round") unless frozen
        Array(frozen).each do |version|
          next if cleared?(action, version)

          finding(event, "passed the blocking gate of rule #{version.rule_id} (version #{version.version}) " \
            "with no earlier check that passed, did not apply, was withdrawn or was overridden")
        end
        @approvals << action
      end

      def cleared?(action, version)
        @action_checks[[ *action, version.id ]].any? do |id|
          row = @checks.fetch(id)
          row[:overridden] || CLEARED.include?(row[:result])
        end
      end

      def finding(event, problem)
        @findings << "seq #{event.seq}: #{event.type} #{problem}" if event.seq > @after_seq
      end
    end

    def gate_findings(group, row, pending, audit, label)
      command = pending&.command || row&.command
      other = RUN_AS[command]
      command = other if other && group.events.any? { |event| event.type == GATED.fetch(other).first }
      move, hook = GATED[command]
      return [] unless move

      group.events.select { |event| event.type == move }.flat_map do |event|
        versions = frozen(pending, audit).select { |version| blocking_gate?(version, hook) }
        versions.reject { |version| cleared?(event, version, hook, audit.fetch(:rounds)[event.task_id]) }.map do |version|
          "#{label}: #{move} past the blocking gate of rule #{version.rule_id} (version #{version.version}) " \
            "with no check that passed, did not apply, was withdrawn or was overridden"
        end
      end
    end

    # The rule versions the command was asked with whose rules are on at
    # this point of the log: its pending transition's (a frozen rule
    # turned off or removed since no longer blocks, L380, L976, even when
    # its check had already failed), or the rules on now. A frozen rule
    # the log never created (a test's setup) counts as on.
    def frozen(pending, audit)
      rules = audit.fetch(:rules)
      return RuleVersion.where(id: rules.values.select { |rule| rule[:enabled] }.pluck(:version_id)).to_a unless pending

      RuleVersion.where(id: pending.frozen_rule_version_ids).to_a.reject { |version| rules[version.rule_id]&.fetch(:enabled) == false }
    end

    def blocking_gate?(version, hook)
      version.hook == hook && version.kind == "gate" && version.on_fail != "warn" && Rules::AppCheckers.runs?(version)
    end

    def cleared?(event, version, hook, round)
      scope = RuleCheck.where(workspace_id: event.workspace_id, task_id: event.task_id, rule_version_id: version.id, hook: hook,
        round: round)
      scope = scope.where(subject_kind: "seat", subject_id: event.payload.fetch("seat_id")) if hook == "task.before_claim"
      scope = scope.where(subject_kind: "review", subject_id: event.subject_id) if hook == "task.before_done"
      scope.where(result: CLEARED).or(scope.where.not(overridden_at: nil)).exists?
    end

    def extra_events(row)
      (row.fetch("conditional_events") + row.fetch("side_events")).map { |entry| entry.fetch("event") }
    end

    def side_types
      @side_types ||= begin
        marked = Contract.registry.fetch("event_types").select { |entry| entry["written_as_side_event"] }
          .map { |entry| entry.fetch("type") }
        exceptions = Contract.state_machine.fetch("side_event_exceptions").map { |entry| entry.fetch("event") }
        (marked + exceptions - ROW_ONLY).to_set
      end
    end

    # --- steps and times ---------------------------------------------------------

    def step_findings(workspace_id, after_seq)
      now = Task.connection.select_value("SELECT clock_timestamp()")
      audited_tasks(workspace_id, after_seq).flat_map do |task_id|
        partition(task_id, now).map { |problem| "steps of task #{task_id}: #{problem}" }
      end
    end

    def time_findings(workspace_id, after_seq)
      audited_tasks(workspace_id, after_seq).filter_map do |task_id|
        times = Event.where(workspace_id: workspace_id, task_id: task_id).order(:seq).pluck(:seq, :effective_at)
        back = times.each_cons(2).find { |(_, earlier), (_, later)| later < earlier }
        "task #{task_id}: effective times go backwards at seq #{back.last.first}" if back
      end
    end

    # The tasks with an event after after_seq.
    def audited_tasks(workspace_id, after_seq)
      Event.where(workspace_id: workspace_id).where("seq > ?", after_seq).where.not(task_id: nil).distinct.pluck(:task_id)
    end

    def partition(task_id, now)
      events = Event.where(task_id: task_id).where(type: [ "task.created", *TERMINAL ]).order(:seq).to_a
      created = events.find { |event| event.type == "task.created" }
      ended = events.find { |event| TERMINAL.include?(event.type) }
      steps = steps_of(task_id)
      return [ "the task has no task.created" ] unless created
      return [ "the task has no step" ] if steps.empty?

      problems = []
      first = steps.first
      unless first.opening_event_id == created.id && first.opened_at == created.effective_at
        problems << "the first step (#{first.kind}) does not open at task.created"
      end
      commands = command_of(steps)
      steps.each_cons(2) do |earlier, later|
        next if earlier.closed_at == later.opened_at && earlier.closing_event_id &&
          commands.fetch(earlier.closing_event_id) == commands.fetch(later.opening_event_id)

        problems << "#{earlier.kind} does not close where #{later.kind} opens"
      end
      open = steps.select { |step| step.closed_at.nil? }
      problems << "#{open.size} steps are open" if open.size > 1
      problems.concat(ending_problems(steps, open, ended))
      problems.concat(steps.filter_map { |step| "#{step.kind} is negative" if step.closed_at && step.closed_at < step.opened_at })
      total = steps.sum { |step| (step.closed_at || now) - step.opened_at }
      lifetime = (ended ? ended.effective_at : now) - created.effective_at
      problems << "the steps sum to #{total} s, the task lived #{lifetime} s" if (total - lifetime).abs > 1e-6
      problems
    end

    def ending_problems(steps, open, ended)
      if ended
        problems = []
        problems << "a step is open after #{ended.type}" if open.any?
        last = steps.last
        unless last.closing_event_id == ended.id && last.closed_at == ended.effective_at
          problems << "the last step (#{last.kind}) does not close at #{ended.type}"
        end
        problems
      else
        open == [ steps.last ] ? [] : [ "the last step is not the one open" ]
      end
    end

    # The command each step's opening and closing event belongs to: its at,
    # which the workspace lock makes one command's own (a waiting command's
    # events written inside it carry another key, RE-3). Within one command a step changes at most once and
    # in place (steps.json), so a step may close at one event of a command
    # and the next open at a later one of the same command (a failed review
    # at the round limit closes review at review.failed and opens wait_owner
    # at hold.opened).
    def command_of(steps)
      ids = steps.flat_map { |step| [ step.opening_event_id, step.closing_event_id ] }.compact
      Event.where(id: ids).pluck(:id, :at).to_h
    end

    def steps_of(task_id)
      rows = TaskStep.where(task_id: task_id).to_a
      seqs = Event.where(id: rows.map(&:opening_event_id)).pluck(:id, :seq).to_h
      rows.sort_by { |row| [ row.opened_at, seqs.fetch(row.opening_event_id, 0) ] }
    end
  end
end
