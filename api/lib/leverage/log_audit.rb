require "set"

module Leverage
  # The log audit (PRD L896: each command wrote the events the lifecycle
  # table names for it, plus only the side events the PRD requires; L895:
  # the steps partition each task's life; milestone 2 plan §2.1). It reads
  # a workspace's log and lists every disagreement as a line; an empty list
  # means the log passes.
  #
  # Commands. The workspace lock makes one command's events one unbroken
  # run of seq sharing at, so the log is cut into groups of consecutive
  # events with the same command_id and at. A group with a key is the
  # command of the commands row with that key (by the caller its actor
  # names when several callers used one key; when the row is gone, purged
  # after 7 days, every command whose rows write the group's first event is
  # tried). A group with no key is a timer's: task.lease_expired is
  # builder_lease_expiry, review.lease_expired review_lease_expiry, and a
  # hold.closed of a credential hold (credential_limit or
  # credential_signed_out) with neither is credential_hold_release
  # (milestone 3 plan §2.1 rule 8), one group per task. Any other event
  # with no key is a finding.
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
  # touch several tasks; any other touches one.
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
    TERMINAL = %w[task.done task.cancelled].freeze
    REFUSED_MAY_WRITE = /\A(check|hold|inbox)\./
    LEASE_FIELD = "lease_seat_id".freeze

    Group = Data.define(:command_id, :at, :events)

    module_function

    # Every finding for the workspace, as lines. after_seq: audit only the
    # commands after it (the log before it is still folded for the tasks'
    # states), for a log whose start was built by a test's Scenario.
    def call(workspace_id, after_seq: 0)
      states = {}
      findings = []
      groups(workspace_id).each do |group|
        if group.events.first.seq > after_seq
          findings.concat(audit_group(workspace_id, group, states))
        else
          group.events.each { |event| states[event.task_id] = observe(states[event.task_id], [ event ]) if event.task_id }
        end
      end
      findings + step_findings(workspace_id, after_seq) + time_findings(workspace_id, after_seq)
    end

    # --- commands --------------------------------------------------------------

    def groups(workspace_id)
      result = []
      Replay.each_event(workspace_id) do |event|
        last = result.last
        if last && last.command_id == event.command_id && last.at == event.at
          last.events << event
        else
          result << Group.new(command_id: event.command_id, at: event.at, events: [ event ])
        end
      end
      result
    end

    def audit_group(workspace_id, group, states)
      return timer_groups(group, states) if group.command_id.nil?

      row = command_row(workspace_id, group)
      label = "command #{group.command_id} (seq #{group.events.first.seq})"
      if row&.outcome == "refused"
        own = group.events.map(&:type).grep_v(REFUSED_MAY_WRITE)
        advance(group.events, states)
        return own.empty? ? [] : [ "#{label}: #{row.command} was refused but wrote #{own.uniq.join(", ")}" ]
      end
      names = row ? [ row.command ] : candidates(group.events.first.type)
      problems = names.map { |name| match(name, group.events, states) }
      advance(group.events, states)
      best = problems.min_by(&:size)
      return [] if best.empty?

      [ "#{label}: #{names.join(" or ")} #{best.join("; ")}" ]
    end

    def timer_groups(group, states)
      group.events.group_by(&:task_id).flat_map do |task_id, events|
        types = events.map(&:type)
        name = types.filter_map { |type| TIMER_EVENTS[type] }.first || credential_release(events)
        label = "events with no command (seq #{events.first.seq}, #{types.uniq.join(", ")})"
        problems = name ? match(name, events, states) : [ "no timer writes them" ]
        advance(events, states) if task_id
        problems.empty? ? [] : [ "#{label}: #{name || "no command"} #{problems.join("; ")}" ]
      end
    end

    # credential_hold_release when the events close a credential hold.
    def credential_release(events)
      closes = events.select { |event| event.type == "hold.closed" }
      return unless closes.any? && closes.all? { |event| CREDENTIAL_HOLDS.include?((event.payload || {})["reason"]) }

      CREDENTIAL_HOLD_RELEASE
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
      named = all_rows.select { |row| row.fetch("command") == name && row.fetch("refusal").nil? }
      stateless = named.any? && named.none? { |row| row.fetch("from") || row.fetch("to") }
      return [ "touches #{tasks.size} tasks" ] if tasks.size > 1 && !stateless

      task = tasks.first unless tasks.size > 1
      state = task && states[task]
      types = events.map(&:type)
      fresh = events.any? { |event| (event.payload || {})[LEASE_FIELD] }
      observed = task ? observe(state, events) : nil
      rows = named.select { |row| row.fetch("from").nil? || row.fetch("from") == state }
      kept = pick(rows, types, fresh, observed)
      return [ "has no row from #{state.inspect} that writes #{types.join(", ")}" ] if kept.empty?

      allowed = kept.flat_map { |row| row.fetch("events") + extra_events(row) }.to_set
      stray = types.reject { |type| allowed.include?(type) || side_types.include?(type) }
      problems = []
      problems << "wrote #{stray.uniq.join(", ")}, which no matched row allows" unless stray.empty?
      stateful = kept.select { |row| row.fetch("from") || row.fetch("to") }
      if task && stateful.any? && stateful.none? { |row| (row.fetch("to") || row.fetch("from")) == observed }
        problems << "led #{task} from #{state.inspect} to #{observed.inspect}, which no matched row allows"
      end
      problems
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

    # The command each step's opening and closing event belongs to: its
    # command_id and at. Within one command a step changes at most once and
    # in place (steps.json), so a step may close at one event of a command
    # and the next open at a later one of the same command (a failed review
    # at the round limit closes review at review.failed and opens wait_owner
    # at hold.opened).
    def command_of(steps)
      ids = steps.flat_map { |step| [ step.opening_event_id, step.closing_event_id ] }.compact
      Event.where(id: ids).pluck(:id, :command_id, :at).to_h { |id, command_id, at| [ id, [ command_id, at ] ] }
    end

    def steps_of(task_id)
      rows = TaskStep.where(task_id: task_id).to_a
      seqs = Event.where(id: rows.map(&:opening_event_id)).pluck(:id, :seq).to_h
      rows.sort_by { |row| [ row.opened_at, seqs.fetch(row.opening_event_id, 0) ] }
    end
  end
end
