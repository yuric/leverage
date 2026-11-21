require_relative "contract_helper"
require "set"
require "time"

# api/contract/traces/*.json: the golden traces (PRD, Quality requirements,
# test 8; plan IF-33). Each trace is replayed here against the rest of the
# contract: the registry, the payload schemas, the state table, the step
# table and the interface schema. Nothing is checked against a copy of a PRD
# table; every name comes from those files.
class TracesTest < Minitest::Test
  include ContractTestHelpers

  # The eight traces plan IF-33 names, the two the core loop's plan adds
  # for a workspace with no rules (milestone 2 plan, TS-8; PRD Q-13), the
  # five the handoff milestone adds, also with no rules (milestone 3 plan
  # HT-1; PRD R-7), and the four the rule checks milestone adds (milestone
  # 4 plan RT-1), then four for questions and approvals (milestone 5 AT-1).
  NAMES = %w[
    01-happy-path 02-failed-review-rework 03-stop-rework-pass-approve-done
    04-two-actions-custom-rule 05-limit-handoff 06-signed-out-hold-verify
    07-pending-gate-check-error-override 08-lease-expiry-and-cancel
    09-core-loop-no-rules 10-leases-no-rules
    11-limit-handoff-no-rules 12-signed-out-hold-verify-no-rules
    13-limit-next-signed-out-no-rules 14-handoff-edges-no-rules
    15-owner-controls-no-rules
    16-model-gate-and-draft 17-submit-rule-rerun-and-override
    18-claim-gate-done-gate-and-ends 19-provider-rule-offline-and-jobs
    20-questions-and-access 21-money-projects-escalation
    22-finishing-edges 23-owner-housekeeping
  ].freeze
  # The traces whose workspace has no rule at all: in the core loop the
  # workspace is created with none (milestone 2 plan, EN-4, Q-12), and no
  # rule exists before milestone 4 (milestone 3 plan HT-1).
  RULE_FREE = %w[
    09-core-loop-no-rules 10-leases-no-rules 11-limit-handoff-no-rules
    12-signed-out-hold-verify-no-rules 13-limit-next-signed-out-no-rules
    14-handoff-edges-no-rules 15-owner-controls-no-rules
  ].freeze
  # The traces whose workspace was made before the rules arrived: their
  # setup has no rule, and their first command is the one-time write of
  # the shipped rules (milestone 4 plan RD-2, RT-1).
  INSTALLED = %w[19-provider-rule-offline-and-jobs].freeze

  START = Time.utc(2026, 11, 19, 9, 0, 0)
  SYMBOL = /\A\$([a-z][a-z_]*):[a-z0-9][a-z0-9_]*\z/
  TIME = /\A@t:(-?[0-9]+)\z/
  EVENT = /\A@event:([1-9][0-9]*)\z/

  # Events whose payload says the builder gets a fresh lease (plan SM-7,
  # SM-8) when lease_seat_id is set.
  LEASE_FIELD = "lease_seat_id".freeze

  # Replays one trace and records every disagreement with the contract.
  # The state each command starts from is derived from the events written
  # so far; the row a command runs is then looked up in state_machine.json.
  class Walk
    attr_reader :trace, :state_failures, :step_failures, :events, :command_of, :lifetimes

    def initialize(trace)
      @trace = trace
      @sm = Leverage::Contract.state_machine
      @registry = Leverage::Contract.registry
      @rows = @sm["groups"].flat_map { |group| group["rows"] }.group_by { |row| row["command"] }
      @command_info = @sm["commands"].to_h { |entry| [ entry["command"], entry ] }
      @side_types = @registry["event_types"].select { |entry| entry["written_as_side_event"] }.map { |entry| entry["type"] }.to_set
      @side_types.merge(@sm["side_event_exceptions"].map { |entry| entry["event"] })
      @operations = @registry["operations"].to_h { |op| [ op["operation_id"], op ] }
      @steps = Leverage::Contract.steps["steps"].to_h { |entry| [ entry["kind"], entry ] }
      @close_without_opening = Leverage::Contract.steps["close_without_opening"]
      @hold_steps = @registry["hold_reasons"].to_h { |entry| [ entry["reason"], entry["step"] ] }
      @failed_gates = Leverage::Contract.hooks["hooks"].to_h { |entry| [ entry["hook"], entry["failed_gate"] ] }
      @events = trace["commands"].flat_map { |command| command["expect"]["events"] }
      @by_ref = @events.to_h { |event| [ event["ref"], event ] }
      @command_of = {}
      trace["commands"].each_with_index { |command, index| command["expect"]["events"].each { |event| @command_of[event["ref"]] = index } }
      @state_failures = []
      @step_failures = []
      @lifetimes = {}
      run
    end

    private

    def seconds(time) = Integer(TIME.match(time)[1], 10)
    def number(ref) = Integer(EVENT.match(ref)[1], 10)

    def run
      @state = {}
      @round = Hash.new(0)
      @pending = {}
      @holds = Hash.new { |hash, key| hash[key] = [] }
      @open = {}
      @acked = {}
      @review_acked = {}
      @reviews = {}
      @actions = {}
      @checks = {}
      @lease_ended = Set.new
      @created_at = {}
      @step_seconds = Hash.new(0)
      trace["commands"].each_with_index { |command, index| step_command(command, index) }
    end

    def fail_state(index, message) = @state_failures << "command #{index + 1} (#{trace["commands"][index]["command"]}): #{message}"
    def fail_step(index, message) = @step_failures << "command #{index + 1} (#{trace["commands"][index]["command"]}): #{message}"

    def step_command(command, index)
      expect = command["expect"]
      events = expect["events"]
      remember_subjects(events)
      target = target_task(command, events)
      holds_before = target ? @holds[target].dup : []
      check_outcome(command, index, target, holds_before)
      apply_holds(events, index)
      check_rounds(events, index)
      check_steps(command, index)
      track_leases(events, command)
    end

    # The task a command is about: the task of its own events when there is
    # one, else the task its path or body names.
    def target_task(command, events)
      own = events.select { |event| own_event?(command, event) }.map { |event| event["task_id"] }.compact.uniq
      return own.first if own.size == 1

      named = named_task(command)
      return named if named

      own.first
    end

    def named_task(command)
      op = @operations[command["operation_id"]]
      id = command["path_params"]["id"]
      if op && id
        return id if op["path"].match?(%r{\A/v1/(owner/)?tasks/\{id\}})
        return @reviews[id] if op["path"].start_with?("/v1/reviews/{id}")
        return @actions[id] if op["path"].start_with?("/v1/owner/actions/{id}")
        return @checks[id] if op["path"].start_with?("/v1/owner/rule-checks/{id}")
      end
      body_task = command["body"]["task_id"]
      body_task.is_a?(String) ? body_task : nil
    end

    def remember_subjects(events)
      events.each do |event|
        next unless event["task_id"]

        case event["subject_kind"]
        when "review" then @reviews[event["subject_id"]] = event["task_id"]
        when "action" then @actions[event["subject_id"]] = event["task_id"]
        when "rule_check" then @checks[event["subject_id"]] = event["task_id"]
        end
      end
    end

    def own_event?(command, event)
      command["caller"] == "app" || event["command_id"].nil? || event["command_id"] == command["key"]
    end

    def command_names(command)
      op = @operations[command["operation_id"]]
      op ? op["commands"] : [ command["command"] ]
    end

    def check_outcome(command, index, target, holds_before)
      expect = command["expect"]
      case expect["outcome"]
      when "refused" then check_refused(command, index, target)
      when "pending" then check_pending(command, index, target)
      else check_completed(command, index, target, holds_before)
      end
    end

    def check_refused(command, index, target)
      code = command["expect"]["refusal"]&.fetch("code")
      fail_state(index, "a refused command names its refusal") unless code
      odd = command["expect"]["events"].map { |event| event["type"] }.reject { |type| type.start_with?("check.", "hold.", "inbox.") }
      fail_state(index, "a refused command writes only rule check, hold and Needs you events, not #{odd}") unless odd.empty?
      return unless target

      state = @state[target]
      case code
      when "invalid_state"
        rows = state_rows(command_names(command), state)
        allowed = rows.reject { |row| row["refusal"] }
        unless allowed.empty? || rows.any? { |row| row["refusal"] == "invalid_state" }
          fail_state(index, "invalid_state, but the state table allows #{command["command"]} from #{state}")
        end
      when "task_cancelled"
        fail_state(index, "task_cancelled, but #{target} is #{state}") unless state == "cancelled"
      when "lease_expired"
        fail_state(index, "lease_expired, but no lease of #{target} has ended") unless @lease_ended.include?(target)
      end
    end

    def check_pending(command, index, target)
      fail_state(index, "a pending command names no refusal") if command["expect"]["refusal"]
      unless target
        fail_state(index, "a pending command must be about a task")
        return
      end
      rows = state_rows(command_names(command), @state[target]).reject { |row| row["refusal"] }
      fail_state(index, "#{command["command"]} is not allowed from #{@state[target]}") if rows.empty?
      odd = command["expect"]["events"].reject { |event| written_while_pending?(event, rows) }.map { |event| event["type"] }
      fail_state(index, "a pending command writes only rule check and job events, and what its rows allow beside them, not #{odd}") unless odd.empty?
      @pending[command["key"]] = { task: target, names: command_names(command), from: @state[target], index: index }
    end

    # What a command that answers pending may write: its checks and jobs;
    # the holds its rows open or close with their items (Complete contract
    # first closes contract_incomplete, L175; a fourth run on changed inputs
    # opens rerun_limit instead of queueing, milestone 4 plan RD-45); and a
    # job result's own row (job.finished, cost.reported), whose Complete
    # contract waits (milestone 4 plan RE-6).
    def written_while_pending?(event, rows)
      type = event["type"]
      return true if type.start_with?("check.", "job.")
      return true if rows.any? { |row| row["from"].nil? && row["events"].include?(type) }

      case type
      when "hold.opened" then rows.any? { |row| row["holds_opened"].include?(event["payload"]["reason"]) }
      when "hold.closed" then rows.any? { |row| row["holds_closed"].include?(event["payload"]["reason"]) }
      when "inbox.opened", "inbox.resolved" then rows.any? { |row| row["side_events"].any? { |entry| entry["event"] == type } }
      else false
      end
    end

    def check_completed(command, index, target, holds_before)
      fail_state(index, "a completed command names no refusal") if command["expect"]["refusal"]
      events = command["expect"]["events"]
      own = events.select { |event| own_event?(command, event) }
      completions = events.reject { |event| own_event?(command, event) }
      check_blocking(command, index, target, holds_before)
      check_work_call(command, index, target)
      if own.empty?
        quiet_command(command, index, target)
      else
        # A row's own events that name no task (seat.changed, seat.removed)
        # count for the task its conditional events move (milestone 3 plan
        # HE-27: turning a seat off releases its Working task).
        taskless = own.reject { |event| event["task_id"] }.map { |event| event["type"] }
        matched = own.group_by { |event| event["task_id"] }.map do |task, group|
          match(index, command_names(command), task, task ? @state[task] : nil, group, target, task ? taskless : [])
        end
        unless matched.flatten.any? { |row| command_names(command).include?(row["command"]) }
          fail_state(index, "no row of #{command_names(command)} fits the events #{own.map { |event| event["type"] }}")
        end
      end
      completions.group_by { |event| event["command_id"] }.each { |key, group| complete(index, key, group) }
    end

    def quiet_command(command, index, target)
      state = target ? @state[target] : nil
      rows = state_rows(command_names(command), state).reject { |row| row["refusal"] }
      return if rows.any? { |row| row["events"].empty? }

      fail_state(index, "#{command["command"]} writes no event, but every row from #{state.inspect} writes one")
    end

    def complete(index, key, events)
      pending = @pending.delete(key)
      unless pending
        fail_state(index, "events carry #{key}, which is no pending command's key")
        return
      end
      events.each do |event|
        cause = @by_ref[event["cause_id"]]
        # L241, and milestone 4 plan RE-3: the check.finished or the
        # check.overridden that settled it.
        unless cause && %w[check.finished check.overridden].include?(cause["type"])
          fail_state(index, "#{event["ref"]} completes #{key}: its cause_id names the check.finished or check.overridden event")
        end
        fail_state(index, "#{event["ref"]} completes a transition on another task") unless event["task_id"] == pending[:task]
      end
      matched = match(index, pending[:names], pending[:task], pending[:from], events, pending[:task])
      fail_state(index, "no row of the pending #{pending[:names]} fits its completion") if matched.empty?
    end

    def check_blocking(command, index, target, holds_before)
      info = @command_info[command["command"]]
      return unless info && info["blocked_by_hold"] && target && holds_before.any?

      fail_state(index, "#{command["command"]} is blocked by a hold (#{holds_before.map { |hold| hold[:reason] }}), so it must be refused on_hold")
    end

    def check_work_call(command, index, target)
      info = @command_info[command["command"]]
      return unless info && info["work_call"] && target && command["caller"].start_with?("$seat:")

      acked = %w[pass_review fail_review].include?(command["command"]) ? @review_acked[target] : @acked[target]
      fail_state(index, "a work call before the briefing is acknowledged under the current lease") unless acked
    end

    def state_rows(names, state)
      rows = names.flat_map { |name| @rows.fetch(name, []) }.select { |row| row["from"].nil? || row["from"] == state }
      rows + rows.filter_map { |row| failed_gate_row(row) }
    end

    # A gate that fails at a hook whose failed gate is
    # hold_contract_incomplete (hooks.json) still commits the contract
    # change, then holds the task with contract_incomplete, which stays in
    # its state: the command reads completed, at once or when a model check
    # fails later (milestone 4 plan section 2.1, rule 7; RD-10). The row
    # this reads as is the gated row with that change and the hold as its
    # events, and its from-state as its to-state.
    def failed_gate_row(row)
      return if row["refusal"] || @failed_gates[row["hook"]] != "hold_contract_incomplete"

      row.merge("events" => (row["events"] & [ "task.contract_changed" ]) + [ "hold.opened" ], "to" => row["from"],
                "holds_opened" => [ "contract_incomplete" ])
    end

    # Finds the rows of names, from state, that the events of one task fit,
    # applies the state they lead to, and returns them. Every row's own
    # events must be written; every event written must belong to a matched
    # row or be a side event; the state the events lead to must be the
    # rows' to-state.
    def match(index, names, task, state, events, target, taskless = [])
      types = events.map { |event| event["type"] }
      fresh = events.any? { |event| event["payload"][LEASE_FIELD] }
      observed = observe(state, events)
      groups = state_rows(names, state).reject { |row| row["refusal"] }.group_by { |row| [ row["command"], row["from"] ] }
      kept = groups.values.flat_map { |rows| pick(rows, types + taskless, fresh, state, observed) }
      allowed = kept.flat_map { |row| row["events"] + (row["conditional_events"] + row["side_events"]).map { |entry| entry["event"] } }.to_set
      stray = types.reject { |type| allowed.include?(type) || @side_types.include?(type) }
      fail_state(index, "#{task.inspect}: no matched row writes #{stray.uniq} (rows: #{kept.map { |row| row["command"] }.uniq})") unless stray.empty?
      if task
        if kept.any? { |row| row["from"] || row["to"] } || observed != state
          unless kept.any? { |row| (row["from"] || row["to"]) && (row["to"] || row["from"]) == observed } ||
                 conditional_move?(kept, types, state, observed)
            fail_state(index, "#{task}: the events lead from #{state.inspect} to #{observed.inspect}, which no row of #{names} allows")
          end
        end
        @state[task] = observed
      end
      if kept.empty? && task == target && !types.all? { |type| @side_types.include?(type) }
        fail_state(index, "#{task.inspect}: no row of #{names} from #{state.inspect} fits #{types}")
      end
      kept
    end

    # A row that names no state may move a task only by one of its
    # conditional events, and only as a row whose own event that is moves it
    # (change_seat's task.released moves Working to Ready as release does).
    def conditional_move?(kept, types, state, observed)
      return false if kept.empty? || kept.any? { |row| row["from"] || row["to"] }

      moves = types & kept.flat_map { |row| row["conditional_events"].map { |entry| entry["event"] } }
      moves.any? do |type|
        @rows.values.flatten.any? { |row| !row["refusal"] && row["events"].include?(type) && row["from"] == state && row["to"] == observed }
      end
    end

    def pick(rows, types, fresh, state, observed)
      fit = rows.select { |row| (row["events"] - types).empty? }
      return [] if fit.empty?

      if fit.any? { |row| row["builder_lease"] == "fresh" } && fit.any? { |row| row["builder_lease"] != "fresh" }
        fit = fit.select { |row| (row["builder_lease"] == "fresh") == fresh }
      end
      if fit.any? { |row| row["from"] || row["to"] }
        leads = fit.select { |row| (row["to"] || row["from"]) == observed }
        fit = leads unless leads.empty?
      end
      most = fit.map { |row| row["events"].size }.max
      fit.select { |row| row["events"].size == most }
    end

    # The state a task's events lead to, read from the events alone.
    def observe(state, events)
      events.reduce(state) do |current, event|
        payload = event["payload"]
        case event["type"]
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

    def apply_holds(events, index)
      events.each do |event|
        task = event["task_id"]
        case event["type"]
        when "hold.opened"
          @holds[task] << { id: event["subject_id"], reason: event["payload"]["reason"], credential: event["payload"]["credential_id"] }
        when "hold.closed"
          open = @holds[task].find { |hold| hold[:id] == event["subject_id"] }
          if open
            @holds[task].delete(open)
            fail_state(index, "#{event["ref"]} closes #{open[:reason]} with reason #{event["payload"]["reason"]}") if open[:reason] != event["payload"]["reason"]
          else
            fail_state(index, "#{event["ref"]} closes a hold that is not open")
          end
        end
      end
    end

    def check_rounds(events, index)
      events.group_by { |event| event["task_id"] }.each do |task, group|
        next unless task

        group.each do |event|
          fail_state(index, "#{event["ref"]} carries round #{event["round"]}, the task is in round #{@round[task]}") unless event["round"] == @round[task]
        end
        @round[task] += 1 if group.any? { |event| %w[review.failed task.returned_for_rework].include?(event["type"]) }
      end
    end

    def track_leases(events, command)
      events.each do |event|
        task = event["task_id"]
        next unless task

        case event["type"]
        when "task.claimed" then @acked[task] = false
        when "review.started" then @review_acked[task] = false
        when "task.briefing_acknowledged"
          event["subject_kind"] == "review" ? @review_acked[task] = true : @acked[task] = true
        when "task.lease_expired" then @lease_ended << task
        end
        @acked[task] = false if event["payload"][LEASE_FIELD]
      end
    end

    # Steps: each command opens and closes them only on the events
    # steps.json allows, exactly one is open from creation to Done or
    # Cancelled, they touch end to end, and the waiting step follows the
    # oldest open hold.
    def check_steps(command, index)
      expect = command["expect"]
      refs = expect["events"].to_h { |event| [ event["ref"], event ] }
      tasks = (expect["steps_opened"] + expect["steps_closed"]).map { |step| step["task_id"] }.uniq
      tasks.each do |task|
        closed = expect["steps_closed"].select { |step| step["task_id"] == task }
        opened = expect["steps_opened"].select { |step| step["task_id"] == task }
        fail_step(index, "#{task}: at most one step closes and one opens per command") if closed.size > 1 || opened.size > 1
        close_step(index, task, closed.first, opened.first, refs) if closed.first
        open_step(index, task, opened.first, refs) if opened.first
        if opened.first && closed.first && number(opened.first["opening_event_id"]) < number(closed.first["closing_event_id"])
          fail_step(index, "#{task}: the new step opens before the old one closes")
        end
      end
      expect["events"].each do |event|
        task = event["task_id"]
        next unless task

        @created_at[task] ||= seconds(event["effective_at"]) if event["type"] == "task.created"
        if %w[task.done task.cancelled].include?(event["type"])
          fail_step(index, "#{task}: a step is still open after #{event["type"]}") if @open[task]
          @lifetimes[task] = [ seconds(event["effective_at"]) - @created_at.fetch(task, 0), @step_seconds[task] ]
        end
      end
      check_open_steps(index, expect["events"])
    end

    def close_step(index, task, step, opened, refs)
      event = refs[step["closing_event_id"]]
      open = @open[task]
      fail_step(index, "#{task}: closes #{step["kind"]}, but #{open&.fetch(:kind).inspect} is open") unless open && open[:kind] == step["kind"]
      unless event && event["task_id"] == task
        fail_step(index, "#{task}: #{step["closing_event_id"]} is not one of this command's events on the task")
        return
      end
      allowed = @steps.fetch(step["kind"], {}).fetch("closed_by", []).map { |entry| entry["event"] } + @close_without_opening
      fail_step(index, "#{task}: #{event["type"]} does not close #{step["kind"]}") unless allowed.include?(event["type"])
      unless opened || @close_without_opening.include?(event["type"])
        fail_step(index, "#{task}: #{step["kind"]} closes and nothing opens, but #{event["type"]} is not #{@close_without_opening}")
      end
      if open
        length = seconds(event["effective_at"]) - open[:at]
        fail_step(index, "#{task}: #{step["kind"]} has a negative duration") if length.negative?
        @step_seconds[task] += length
      end
      @open.delete(task)
    end

    def open_step(index, task, step, refs)
      fail_step(index, "#{task}: #{step["kind"]} opens while #{@open[task][:kind]} stays open") if @open[task]
      event = refs[step["opening_event_id"]]
      unless event && event["task_id"] == task
        fail_step(index, "#{task}: #{step["opening_event_id"]} is not one of this command's events on the task")
        return
      end
      kind = @steps[step["kind"]]
      unless kind
        fail_step(index, "#{task}: #{step["kind"]} is not a step kind")
        return
      end
      fail_step(index, "#{task}: #{event["type"]} does not open #{step["kind"]}") unless kind["opened_by"].any? { |entry| entry["event"] == event["type"] }
      fail_step(index, "#{task}: #{step["kind"]} has class #{kind["class"]}") unless step["step_class"] == kind["class"]
      fail_step(index, "#{task}: #{step["kind"]} has no subject #{step["subject_kind"].inspect}") unless kind["subject_kinds"].include?(step["subject_kind"])
      fail_step(index, "#{task}: subject_id and subject_kind are null together") unless step["subject_kind"].nil? == step["subject_id"].nil?
      fail_step(index, "#{task}: #{step["kind"]} has no cause #{step["cause_kind"]}") unless step["cause_kind"].nil? || kind["cause_kinds"].include?(step["cause_kind"])
      fail_step(index, "#{task}: cause_rule_id is set exactly for a rule cause") unless (step["cause_kind"] == "rule") == !step["cause_rule_id"].nil?
      round = @round[task]
      fail_step(index, "#{task}: #{step["kind"]} opens in round #{step["round"]}, the task is in round #{round}") unless step["round"] == round
      if step["kind"] == "wait_ready"
        cause = event["payload"].fetch("wait_cause") { fail_step(index, "#{event["type"]} opens wait_ready without wait_cause (plan SM-41)") }
        fail_step(index, "#{task}: wait_ready's cause is the opening event's wait_cause") unless (step["cause_kind"] == "credential_limit") == (cause == "credential_limit")
      end
      @open[task] = { kind: step["kind"], subject: step["subject_id"], at: seconds(event["effective_at"]) }
    end

    def check_open_steps(index, events)
      events.map { |event| event["task_id"] }.compact.uniq.each do |task|
        state = @state[task]
        next if %w[done cancelled].include?(state)

        open = @open[task]
        unless open
          fail_step(index, "#{task}: no step is open")
          next
        end
        holds = @holds[task]
        if holds.empty?
          fail_step(index, "#{task}: #{open[:kind]} is open with no hold") if %w[wait_owner wait_seat wait_limit].include?(open[:kind])
          next
        end
        oldest = holds.first
        expected = @hold_steps[oldest[:reason]]
        fail_step(index, "#{task}: the oldest hold is #{oldest[:reason]}, so #{expected} is open, not #{open[:kind]}") unless open[:kind] == expected
        fail_step(index, "#{task}: wait_owner's subject is the oldest hold") if expected == "wait_owner" && open[:subject] != oldest[:id]
        fail_step(index, "#{task}: wait_limit's subject is the hold's credential") if expected == "wait_limit" && open[:subject] != oldest[:credential]
      end
    end
  end

  def traces = NAMES.to_h { |name| [ name, Leverage::Contract.trace(name) ] }
  def walk(name) = (@walks ||= {})[name] ||= Walk.new(Leverage::Contract.trace(name))
  def binder = Leverage::Contract::TraceBinder.new(start: START)
  def operations = registry["operations"].to_h { |op| [ op["operation_id"], op ] }
  def seconds(time) = Integer(TIME.match(time)[1], 10)
  def all_events(trace) = trace["commands"].flat_map { |command| command["expect"]["events"] }

  def test_the_traces_of_if_33_and_ts_8_exist_and_no_other
    files = Dir.glob("*.json", base: File.join(CONTRACT_ROOT, "traces")).map { |file| File.basename(file, ".json") }.sort
    assert_equal NAMES, files
    traces.each { |name, trace| assert_equal name, trace["name"] }
  end

  def test_each_trace_follows_the_trace_schema
    traces.each { |name, trace| assert_empty meta_errors("trace", trace), name }
  end

  def test_every_symbol_binds
    traces.each_value do |trace|
      bound = binder.bind(trace)
      assert_equal binder.id("$task:1"), binder.bind("$task:1")
      refute_includes JSON.generate(bound), "\"$", trace["name"]
    end
  end

  def test_setup_names_registered_values_and_every_shipped_rule
    shipped = Leverage::Contract.shipped_rules["rules"].map { |rule| rule["key"] }
    providers = registry["credential_providers"].map { |entry| entry["provider"] }
    traces.each do |name, trace|
      setup = trace["setup"]
      ids = setup.values_at("users", "helpers", "credentials", "seats", "projects", "rules").flatten.map { |row| row["id"] }
      assert_empty duplicates(ids), name
      rules = setup["rules"]
      assert_equal (RULE_FREE + INSTALLED).include?(name), rules.empty?, "#{name}: only the rule-free traces and those that install the rules have no rules"
      unless rules.empty?
        shipped.each { |key| assert_equal 1, rules.count { |rule| rule["key"] == key && rule["origin"] == "shipped" }, "#{name}: #{key}" }
      end
      if INSTALLED.include?(name)
        first = trace["commands"].first
        assert_equal [ "install_shipped_rules", "app" ], first.values_at("command", "caller"), "#{name}: the rules are written first"
        assert_equal shipped.map { |key| "$rule:#{key}" }, first["expect"]["events"].map { |event| event["subject_id"] }, name
      end
      rules.each do |rule|
        assert_includes [ true, false ], rule["enabled"], "#{name}: #{rule["id"]}"
        assert_match(/\A\$rule_version:/, rule["current_version_id"], "#{name}: #{rule["id"]}")
      end
      setup["seats"].each do |seat|
        assert_includes Leverage::Contract.list("seat_roles"), seat["role"], "#{name}: #{seat["id"]}"
        assert_includes providers, seat["provider"], "#{name}: #{seat["id"]}"
        assert(seat["credential_id"].nil? || ids.include?(seat["credential_id"]), "#{name}: #{seat["id"]} names an unknown credential")
      end
      setup["credentials"].each do |credential|
        assert_includes providers, credential["provider"], "#{name}: #{credential["id"]}"
        assert_includes Leverage::Contract.list("credential_kinds"), credential["kind"], "#{name}: #{credential["id"]}"
        assert_includes Leverage::Contract.list("credential_states"), credential["state"], "#{name}: #{credential["id"]}"
      end
      setup["settings"].each_key { |key| assert_match SNAKE_CASE, key, name }
    end
  end

  def test_every_command_is_a_registered_call_from_a_caller_it_allows
    callers = { "owner" => "user", "helper" => "helper" }
    openapi = JSONSchemer.openapi(Leverage::Contract.openapi)
    traces.each do |name, trace|
      keys = []
      trace["commands"].each_with_index do |command, index|
        where = "#{name} command #{index + 1}"
        assert_includes registry["commands"], command["command"], where
        if command["caller"] == "app"
          assert_nil command["operation_id"], where
          assert_nil command["key"], where
          rows = Leverage::Contract.state_machine["groups"].flat_map { |group| group["rows"] }.select { |row| row["command"] == command["command"] }
          assert rows.all? { |row| row["who"] == [ "app" ] }, "#{where}: only a timer or the app's own command runs with caller app"
          next
        end
        op = operations.fetch(command["operation_id"]) { flunk "#{where}: unknown operation #{command["operation_id"]}" }
        assert_includes op["commands"], command["command"], where
        assert_equal "POST", op["method"], where
        kind = SYMBOL.match(command["caller"])[1]
        assert_equal callers.fetch(op["tag"], "seat"), kind, "#{where}: #{op["operation_id"]} is called by #{op["caller"]}"
        refute_nil command["key"], where
        keys << command["key"]
        assert_equal op["path"].scan(/\{([a-z]+)\}/).flatten.sort, command["path_params"].keys.sort, where
        check_body(openapi, op, binder.bind(command["body"]), where)
      end
      assert_empty duplicates(keys), "#{name}: every command sends its own key"
    end
  end

  def check_body(openapi, op, body, where)
    content = Leverage::Contract.openapi["paths"][op["path"]][op["method"].downcase].dig("requestBody", "content", "application/json", "schema")
    if content
      ref = content.fetch("$ref")
      assert_equal [], openapi.ref(ref).validate(body).map { |error| error.fetch("error") }, where
    else
      assert_equal({}, body, "#{where}: #{op["operation_id"]} takes no body")
    end
  end

  def test_events_are_numbered_in_seq_order_and_link_backwards
    traces.each do |name, trace|
      events = all_events(trace)
      assert_equal (1..events.size).map { |number| "@event:#{number}" }, events.map { |event| event["ref"] }, name
      events.each do |event|
        next unless event["cause_id"]

        assert_operator Integer(EVENT.match(event["cause_id"])[1], 10), :<, Integer(EVENT.match(event["ref"])[1], 10), "#{name} #{event["ref"]}"
      end
    end
  end

  def test_every_event_is_registered_and_carries_its_full_payload_unchanged
    traces.each do |name, trace|
      all_events(trace).each do |event|
        where = "#{name} #{event["ref"]} #{event["type"]}"
        entry = Leverage::Contract.event_type(event["type"])
        assert_includes entry["schema_versions"], event["schema_version"], where
        assert_includes entry["subject_kinds"], event["subject_kind"], where
        assert_equal event["subject_kind"].nil?, event["subject_id"].nil?, where
        assert_equal event["task_id"].nil?, event["round"].nil?, "#{where}: round is null exactly when task_id is"
        assert_includes Leverage::Contract.list("actor_kinds"), event["actor_kind"], where
        schema = Leverage::Contract.payload_schema(event["type"], event["schema_version"])
        assert_equal schema["properties"].keys.sort, event["payload"].keys.sort, "#{where}: the payload lists every field"
        assert_equal [], Leverage::Contract.validate_payload(event["type"], event["schema_version"], binder.bind(event["payload"])), where
      end
    end
  end

  def test_times_follow_the_command_and_never_go_backwards
    traces.each do |name, trace|
      last_at = nil
      effective = {}
      trace["commands"].each_with_index do |command, index|
        at = seconds(command["at"])
        assert_operator at, :>=, last_at, "#{name} command #{index + 1}: at never decreases" if last_at
        last_at = at
        command["expect"]["events"].each do |event|
          where = "#{name} #{event["ref"]}"
          assert_equal command["at"], event["at"], "#{where}: every event of a command shares its at"
          if command["caller"] == "app"
            assert_operator seconds(event["effective_at"]), :<=, at, "#{where}: a timer's due time is not after it runs"
          else
            assert_equal event["at"], event["effective_at"], where
          end
          next unless event["task_id"]

          time = seconds(event["effective_at"])
          assert_operator time, :>=, effective[event["task_id"]], "#{where}: effective_at never decreases within a task" if effective[event["task_id"]]
          effective[event["task_id"]] = time
        end
      end
    end
  end

  def test_actors_and_command_ids_follow_the_event_record
    traces.each do |name, trace|
      keys = []
      callers = {}
      trace["commands"].each_with_index do |command, index|
        command["expect"]["events"].each do |event|
          where = "#{name} command #{index + 1} #{event["ref"]}"
          case command["caller"]
          when "app"
            assert_equal [ "app", nil, nil ], event.values_at("actor_kind", "actor_id", "command_id"), "#{where}: the server's own events carry no actor id and no key"
          when /\A\$helper:/
            assert_equal [ "app", command["caller"], command["key"] ], event.values_at("actor_kind", "actor_id", "command_id"), "#{where}: a helper report's events (plan IF-37)"
          else
            # Events that complete a pending transition carry its requester
            # as actor, whoever's command writes them (milestone 4 plan
            # RE-3).
            who = (event["command_id"] != command["key"] && callers[event["command_id"]]) || command["caller"]
            if event["actor_kind"] == "app"
              assert_nil event["actor_id"], where
            else
              assert_equal [ SYMBOL.match(who)[1] == "user" ? "owner" : "seat", who ], event.values_at("actor_kind", "actor_id"), where
            end
            refute_nil event["command_id"], "#{where}: only events of the server's own requests carry no key" if event["actor_kind"] != "app"
            # L241: all events of one command share its key, and events that
            # complete a pending transition carry the original requester's.
            # Only the server's own requests at action.requested carry none.
            if event["command_id"].nil?
              request = event["type"].start_with?("job.") ||
                (event["type"].start_with?("check.") && event["payload"]["hook"] == "action.requested")
              assert request, "#{where}: #{event["type"]} carries no key, but only the checks and jobs at action.requested may"
            else
              assert_includes [ command["key"] ] + keys, event["command_id"], "#{where}: an event carries another command's key"
            end
          end
        end
        keys << command["key"] if command["key"]
        callers[command["key"]] = command["caller"] if command["key"]
      end
    end
  end

  # A trace may fix fields of a command's result. Each is a property of the
  # operation's 200 result, and a claim's credential and model are the ones
  # its claim event records (L588, L688).
  def test_result_fields_belong_to_the_result_and_a_claim_names_its_credential
    openapi = Leverage::Contract.openapi
    claims = { "claim_next_task" => "task.claimed", "claim_next_review" => "review.started", "claim_next_job" => "job.claimed" }
    seen = 0
    traces.each do |name, trace|
      trace["commands"].each_with_index do |command, index|
        fields = command["expect"]["result_fields"] or next
        where = "#{name} command #{index + 1}"
        assert_equal "completed", command["expect"]["outcome"], where
        result = openapi_result(openapi, command["operation_id"])
        assert_empty fields.keys - result.fetch("properties").keys, "#{where}: not fields of the result"
        type = claims[command["operation_id"]] or next
        event = command["expect"]["events"].find { |candidate| candidate["type"] == type }
        %w[credential_id model].each do |field|
          expected = event["payload"][field]
          # A seat whose model is empty records null (milestone 2 plan EN-7).
          expected.nil? ? assert_nil(fields[field], "#{where}: #{field}") : assert_equal(expected, fields[field], "#{where}: #{field}")
        end
        seen += 1
      end
    end
    assert_operator seen, :>=, 2, "trace 05 shows the credential and model of its task and review claims"
  end

  def openapi_result(openapi, operation_id)
    schemas = openapi["components"]["schemas"]
    deref = ->(node) { node = schemas.fetch(node["$ref"].split("/").last) while node["$ref"]; node }
    op = openapi["paths"].values.flat_map(&:values).find { |candidate| candidate.is_a?(Hash) && candidate["operationId"] == operation_id }
    envelope = deref.call(op["responses"]["200"]["content"]["application/json"]["schema"])
    deref.call(envelope["properties"]["result"])
  end

  # One job row per attempt (plan DB-31): a check queued again runs on a new
  # job, and job.requeued is written on the job it replaces.
  def test_each_attempt_of_a_check_runs_on_a_job_of_its_own
    traces.each do |name, trace|
      question_jobs = Set.new
      jobs_by_check = Hash.new { |hash, key| hash[key] = [] }
      all_events(trace).each do |event|
        case event["type"]
        when "check.queued"
          earlier = jobs_by_check[event["subject_id"]]
          refute_includes earlier, event.dig("payload", "job_id"), "#{name} #{event["ref"]}: an attempt reuses a job"
          earlier << event.dig("payload", "job_id")
        when "job.queued"
          question_jobs << event["subject_id"] if event.dig("payload", "kind") == "question"
        when "job.requeued"
          next if question_jobs.include?(event["subject_id"])

          assert jobs_by_check.values.any? { |jobs| jobs.last == event["subject_id"] },
            "#{name} #{event["ref"]}: job.requeued is not on the latest attempt's job"
        end
      end
    end
  end

  def test_outcomes_and_refusals_use_registered_codes
    codes = registry["refusals"].map { |entry| entry["code"] }
    traces.each do |name, trace|
      trace["commands"].each_with_index do |command, index|
        expect = command["expect"]
        where = "#{name} command #{index + 1}"
        assert_equal expect["outcome"] == "refused", !expect["refusal"].nil?, where
        assert_includes codes, expect["refusal"]["code"], where if expect["refusal"]
      end
    end
  end

  def test_each_trace_walks_the_state_table
    NAMES.each { |name| assert_equal [], walk(name).state_failures, name }
  end

  def test_steps_open_and_close_on_the_events_steps_json_allows
    NAMES.each { |name| assert_equal [], walk(name).step_failures, name }
  end

  def test_the_steps_of_a_finished_task_sum_to_its_lifetime
    finished = 0
    NAMES.each do |name|
      walk(name).lifetimes.each do |task, (lifetime, steps)|
        finished += 1
        assert_equal lifetime, steps, "#{name} #{task}"
      end
    end
    assert_operator finished, :>=, NAMES.size - 1, "every trace but 07 takes a task to Done or Cancelled"
  end

  def types_of(name) = all_events(Leverage::Contract.trace(name)).map { |event| event["type"] }

  def test_trace_01_takes_one_task_from_add_to_done
    assert_equal %w[task.created task.ready task.claimed task.submitted review.started review.passed task.done],
      types_of("01-happy-path") & %w[task.created task.ready task.claimed task.submitted review.started review.passed task.done]
  end

  def test_trace_02_fails_a_review_and_opens_and_closes_no_reviewer_eligible
    events = all_events(Leverage::Contract.trace("02-failed-review-rework"))
    failed = events.find { |event| event["type"] == "review.failed" }
    assert failed["payload"][LEASE_FIELD], "the previous builder gets a fresh lease"
    opened = events.find { |event| event["type"] == "inbox.opened" && event["payload"]["kind"] == "no_reviewer_eligible" }
    assert opened, "plan SM-42"
    assert events.any? { |event| event["type"] == "inbox.resolved" && event["subject_id"] == opened["subject_id"] }
    assert_includes types_of("02-failed-review-rework"), "task.done"
  end

  def test_trace_03_has_stop_return_for_rework_pass_approve_and_done
    trace = Leverage::Contract.trace("03-stop-rework-pass-approve-done")
    commands = trace["commands"].map { |command| command["command"] }
    assert_includes commands, "return_for_rework"
    types = types_of(trace["name"])
    %w[action.stopped task.returned_for_rework review.passed action.approved task.done].each { |type| assert_includes types, type }
    assert_operator types.index("action.stopped"), :<, types.rindex("action.approved")
    approved = all_events(trace).find { |event| event["type"] == "action.approved" }
    assert approved["payload"][LEASE_FIELD], "the immediate action lease (plan SM-8)"
  end

  def test_trace_04_has_two_actions_a_custom_rule_and_the_delayed_action_lease
    trace = Leverage::Contract.trace("04-two-actions-custom-rule")
    events = all_events(trace)
    requested = events.select { |event| event["type"] == "action.requested" }
    assert_operator requested.map { |event| event["subject_id"] }.uniq.size, :>=, 2
    add_rule = trace["commands"].find { |command| command["command"] == "add_rule" }
    assert_equal "action.requested", add_rule["body"]["hook"], "PRD test 8: a custom rule at before anything goes out"
    rule = add_rule["expect"]["events"].find { |event| event["type"] == "rule.created" }["subject_id"]
    assert events.any? { |event| event["type"] == "check.queued" && event["payload"]["rule_id"] == rule && event["payload"]["hook"] == "action.requested" }
    granted = events.find { |event| event["type"] == "action.lease_granted" }
    assert granted, "plan SM-8, P-1"
    freeing = trace["commands"][walk(trace["name"]).command_of[granted["ref"]]]
    refute_equal granted["task_id"], freeing["path_params"]["id"], "the command that frees the builder is on another task"
    assert events.any? { |event| event["type"] == "action.approved" && event["task_id"] == granted["task_id"] && event["payload"][LEASE_FIELD].nil? }
  end

  def test_trace_05_hands_off_on_a_limit_and_returns_to_the_seats_own_credential
    trace = Leverage::Contract.trace("05-limit-handoff")
    events = all_events(trace)
    assert trace["commands"].any? { |command| command["caller"].start_with?("$helper:") && command["expect"]["events"].any? }, "plan IF-37"
    switches = events.select { |event| event["type"] == "credential.switched" }
    assert_operator switches.size, :>=, 2
    own = trace["setup"]["seats"].to_h { |seat| [ seat["id"], seat["credential_id"] ] }
    release = trace["commands"].find { |command| command["command"] == "credential_hold_release" }
    back = release["expect"]["events"].find { |event| event["type"] == "credential.switched" }
    assert back, "plan SM-37"
    assert_equal own.fetch(back["payload"]["seat_id"]), back["subject_id"]
    limit = events.find { |event| event["type"] == "hold.opened" && event["payload"]["reason"] == "credential_limit" }
    refute_nil limit["payload"]["credential_id"], "plan SM-41"
  end

  def test_trace_06_holds_on_a_sign_out_until_a_login_is_verified
    types = types_of("06-signed-out-hold-verify")
    %w[credential.signed_out hold.opened credential.verified hold.closed credential.switched].each { |type| assert_includes types, type }
    events = all_events(Leverage::Contract.trace("06-signed-out-hold-verify"))
    assert events.any? { |event| event["type"] == "inbox.opened" && event["payload"]["kind"] == "account_signed_out" }
  end

  def test_trace_07_completes_a_pending_gate_after_an_error_and_an_override
    trace = Leverage::Contract.trace("07-pending-gate-check-error-override")
    pending = trace["commands"].find { |command| command["expect"]["outcome"] == "pending" }
    assert pending
    events = all_events(trace)
    assert events.any? { |event| event["type"] == "check.finished" && event["payload"]["result"] == "error" }
    assert_includes events.map { |event| event["type"] }, "check.overridden"
    assert events.any? { |event| event["command_id"] == pending["key"] && event["type"] == "task.ready" }
  end

  # Recovery time as milestone 3 plan HE-17 reads the PRD (Handoff,
  # Recovery time): it starts at credential.limit_reached, or at a
  # credential.signed_out a run found (seat_id set; one found by Verify
  # starts nothing). Its work is the review the payload names, or else the
  # build work of the task. It ends at the credential.switched for the same
  # work written by the same command (0 seconds), or else at the first
  # later event of that task, by a seat, of a type of that work. Returns
  # [effective second of the start, seconds or nil when it never ends].
  BUILD_WORK = %w[task.claimed task.briefing_acknowledged criterion.started criterion.passed task.submitted task.released].freeze
  REVIEW_WORK = %w[review.started task.briefing_acknowledged review.passed review.failed review.released].freeze

  def recovery_times(name)
    trace = Leverage::Contract.trace(name)
    events = trace["commands"].each_with_index.flat_map { |command, index| command["expect"]["events"].map { |event| [ event, index ] } }
    events.each_with_index.filter_map do |(event, index), position|
      next unless event["type"] == "credential.limit_reached" || (event["type"] == "credential.signed_out" && event["payload"]["seat_id"])

      review = event["payload"]["review_id"]
      same_work = ->(other) { other["task_id"] == event["task_id"] && other["payload"]["review_id"] == review }
      switch = events.find { |other, other_index| other_index == index && other["type"] == "credential.switched" && same_work.call(other) }
      ending = switch&.first || events[(position + 1)..].map(&:first).find do |other|
        next false unless other["task_id"] == event["task_id"] && other["actor_kind"] == "seat"

        if review
          REVIEW_WORK.include?(other["type"]) && other["subject_kind"] == "review" && other["subject_id"] == review
        else
          BUILD_WORK.include?(other["type"]) && other["subject_kind"] != "review"
        end
      end
      start = seconds(event["effective_at"])
      [ start, ending && seconds(ending["effective_at"]) - start ]
    end
  end

  def events_of(name, command) = Leverage::Contract.trace(name)["commands"].select { |entry| entry["command"] == command }.map { |entry| entry["expect"]["events"] }

  def test_trace_11_hands_off_below_waits_for_the_reset_and_returns_with_he_17s_recovery_times
    name = "11-limit-handoff-no-rules"
    events = all_events(Leverage::Contract.trace(name))
    own = Leverage::Contract.trace(name)["setup"]["seats"].to_h { |seat| [ seat["id"], seat["credential_id"] ] }
    first, second = events_of(name, "report_limit")
    assert_equal %w[credential.limit_reached credential.switched], first.map { |event| event["type"] }
    assert_equal %w[credential.limit_reached hold.opened], second.map { |event| event["type"] }, "no item while a reset time is known"
    back = events_of(name, "credential_hold_release").flatten.find { |event| event["type"] == "credential.switched" }
    assert_equal own.fetch(back["payload"]["seat_id"]), back["subject_id"], "back to the seat's own login"
    assert_equal [ [ 600, 0 ], [ 900, 1600 ] ], recovery_times(name), "milestone 3 plan HT-1, HE-17"
    assert_includes events.map { |event| event["type"] }, "task.done"
  end

  def test_trace_12_holds_on_a_sign_out_until_a_login_is_verified_with_he_17s_recovery_time
    name = "12-signed-out-hold-verify-no-rules"
    held = events_of(name, "report_signed_out").first
    assert_equal %w[credential.signed_out hold.opened inbox.opened], held.map { |event| event["type"] }
    assert_equal [ "credential_signed_out", held.first["subject_id"] ], held[1]["payload"].values_at("reason", "credential_id"), "HE-12: the reported login"
    assert_empty events_of(name, "sign_in_again").flatten, "Sign in again writes no event"
    result = events_of(name, "report_request_result").first
    assert_equal %w[credential.verified hold.closed credential.switched inbox.resolved], result.map { |event| event["type"] }
    assert_equal "sign_in_again", result.last["payload"]["choice"], "HE-29"
    assert_equal [ [ 600, 300 ] ], recovery_times(name), "milestone 3 plan HT-1, HE-17"
  end

  def test_trace_13_holds_a_limit_on_the_signed_out_next_login_and_continues_on_it
    name = "13-limit-next-signed-out-no-rules"
    trace = Leverage::Contract.trace(name)
    held = events_of(name, "report_limit").first
    assert_equal %w[credential.limit_reached hold.opened inbox.opened], held.map { |event| event["type"] }
    signed_out = trace["setup"]["credentials"].find { |row| row["state"] == "signed_out" }
    assert_equal [ "credential_signed_out", signed_out["id"] ], held[1]["payload"].values_at("reason", "credential_id"), "HE-12: the next login"
    assert_equal "account_signed_out", held[2]["payload"]["kind"]
    switch = events_of(name, "report_request_result").flatten.find { |event| event["type"] == "credential.switched" }
    assert_equal signed_out["id"], switch["subject_id"]
    assert_equal [ [ 600, 220 ] ], recovery_times(name), "HD-9: the continuing run's criterion.started ends it"
    assert_includes all_events(trace).map { |event| event["type"] }, "task.done"
  end

  def test_trace_14_has_each_edge_of_handoff
    name = "14-handoff-edges-no-rules"
    trace = Leverage::Contract.trace(name)
    commands = trace["commands"]
    types = ->(command) { command["expect"]["events"].map { |event| event["type"] } }
    reports = commands.select { |command| command["command"] == "report_limit" }
    own = trace["setup"]["seats"].to_h { |seat| [ seat["id"], seat["credential_id"] ] }

    no_reset = reports.find { |command| command["body"]["reset_at"].nil? }
    assert_equal %w[credential.limit_reached hold.opened inbox.opened], types.call(no_reset), "a limit with no reset time"
    assert_equal "limit_with_no_reset_time", no_reset["expect"]["events"].last["payload"]["kind"]
    cleared = commands.find { |command| types.call(command) == %w[credential.verified hold.closed inbox.resolved] }
    assert cleared, "a passed Verify closes it (HE-2)"
    assert_nil cleared["expect"]["events"].last["payload"]["choice"]

    beside = commands.find { |command| types.call(command) == %w[credential.signed_out inbox.opened] }
    assert beside, "HE-11: the item opens beside the credential_limit hold"
    assert_nil beside["expect"]["events"].first["payload"]["seat_id"]
    assert commands.any? { |command| types.call(command) == %w[credential.verified inbox.resolved] }, "HE-11: resolved while the hold waits"

    expiry = commands.find { |command| command["command"] == "builder_lease_expiry" }
    assert_equal %w[task.lease_expired hold.closed], types.call(expiry)
    assert_equal [ "credential_limit", "credential_limit" ], expiry["expect"]["events"].last["payload"].values_at("reason", "wait_cause")
    assert_equal "credential_limit", expiry["expect"]["steps_opened"].first["cause_kind"]

    back = reports.find do |command|
      switch = command["expect"]["events"].find { |event| event["type"] == "credential.switched" }
      switch && switch["subject_id"] == own[switch["payload"]["seat_id"]]
    end
    assert back, "HE-4: back to the seat's own login at a report"

    at_once = reports.find { |command| types.call(command) == %w[credential.limit_reached hold.opened] && command["expect"]["events"].last["payload"]["credential_id"] != command["body"]["credential_id"] && commands.any? { |release| release["command"] == "credential_hold_release" && release["expect"]["events"].first["effective_at"] == command["at"] } }
    assert at_once, "HE-4: a hold with no item that the timer closes at once"

    review_switch = reports.find { |command| command["body"]["review_id"] && types.call(command) == %w[credential.limit_reached credential.switched] }
    assert review_switch, "a reviewer's limit that switches"
    task = review_switch["expect"]["events"].first["task_id"]
    built = all_events(trace).select { |event| event["task_id"] == task && %w[task.claimed credential.switched].include?(event["type"]) && event["payload"]["review_id"].nil? }
    provider = trace["setup"]["credentials"].to_h { |row| [ row["id"], row["provider"] ] }
    refute_includes built.map { |event| provider.fetch(event["payload"]["credential_id"] || event["subject_id"]) },
      provider.fetch(review_switch["expect"]["events"].last["subject_id"]), "HE-41: a provider that did not build the task"

    released = commands.find { |command| command["command"] == "report_signed_out" }
    assert_equal %w[credential.signed_out review.released], types.call(released)
    review = released["body"]["review_id"]
    later = commands[(commands.index(released) + 1)..].find { |command| command["command"] == "claim_review" && command["expect"]["events"].first["subject_id"] == review }
    refute_equal released["body"]["seat_id"], later["caller"], "another reviewer claims it"

    failed = commands.find { |command| command["command"] == "fail_review" }
    assert_includes types.call(failed), "credential.switched", "the fresh lease starts on another login"
    assert failed["expect"]["events"].first["payload"]["lease_seat_id"]

    # HE-17, start by start: [start, seconds], nil when the task was
    # cancelled before the seat that continues it wrote anything. A switch
    # in the same command ends one at once; a sign-out found by Verify
    # (seat_id null) starts none; the reviewer's sign-out ends at the other
    # reviewer's review.started.
    assert_equal [ [ 300, 60 ], [ 500, nil ], [ 600, 0 ], [ 700, 0 ], [ 1600, 0 ], [ 1700, 100 ], [ 3800, 0 ], [ 3850, 250 ] ],
      recovery_times(name), "milestone 3 plan HE-17"
  end

  def test_trace_15_uses_each_owner_control
    name = "15-owner-controls-no-rules"
    trace = Leverage::Contract.trace(name)
    commands = trace["commands"].map { |command| command["command"] }
    %w[promote edit_contract hold resume pause_seat resume_seat change_seat].each { |command| assert_includes commands, command }
    assert_equal "imaginarium", trace["commands"].first["body"]["state"]
    edits = trace["commands"].select { |command| command["command"] == "edit_contract" }.map { |command| command["expect"]["events"].map { |event| event["type"] } }
    assert_includes edits, %w[task.contract_changed], "an edit in Backlog"
    assert_includes edits, %w[task.contract_changed task.returned], "an edit in Working"
    assert_includes edits, %w[task.contract_changed task.returned hold.closed inbox.resolved], "an edit answers Past the round limit"
    events = all_events(trace)
    assert events.any? { |event| event["type"] == "inbox.resolved" && event["payload"]["choice"] == "edit_contract" }
    released = events.find { |event| event["type"] == "task.released" && event["payload"]["reason"] == "seat_disabled" }
    assert released, "an agent turned off releases its Working task"
    # PRD L240 (cause_id: the event that led to this one) and the contract
    # README's rule for a plain chain: the change that turns the agent off
    # causes the release, as seat.removed causes remove_seat's (milestone 2
    # plan IN-40) and seat.paused the seat_paused hold in this trace.
    changed = events.find { |event| event["type"] == "seat.changed" }
    assert_equal changed["ref"], released["cause_id"], "task.released is caused by seat.changed"
    assert_equal %w[owner_hold seat_paused rounds_exceeded], events.select { |event| event["type"] == "hold.opened" }.map { |event| event["payload"]["reason"] }
  end

  def test_trace_08_expires_a_lease_at_its_due_time_and_refuses_the_late_call
    trace = Leverage::Contract.trace("08-lease-expiry-and-cancel")
    commands = trace["commands"]
    expiry = commands.index { |command| command["command"] == "builder_lease_expiry" }
    assert expiry
    event = commands[expiry]["expect"]["events"].first
    assert_operator seconds(event["effective_at"]), :<, seconds(event["at"]), "PRD test 7: recorded at the due time"
    late = commands[expiry + 1]
    assert_equal [ "refused", "lease_expired", commands[expiry]["at"] ], [ late["expect"]["outcome"], late["expect"]["refusal"]["code"], late["at"] ]
    assert_includes types_of(trace["name"]), "task.cancelled"
    assert commands.any? { |command| command.dig("expect", "refusal", "code") == "task_cancelled" }
  end

  # Milestone 4 plan RT-1: what each of the four traces of the rule checks
  # milestone shows.
  def commands_of(name) = Leverage::Contract.trace(name)["commands"]
  def types(command) = command["expect"]["events"].map { |event| event["type"] }
  def payloads(events, type) = events.select { |event| event["type"] == type }.map { |event| event["payload"] }

  def test_trace_16_holds_a_contract_a_model_check_failed_and_completes_a_planners_draft
    name = "16-model-gate-and-draft"
    commands = commands_of(name)
    events = all_events(Leverage::Contract.trace(name))
    first = commands.find { |command| command["command"] == "complete_contract" }
    assert_equal "pending", first["expect"]["outcome"]
    failed = commands.find { |command| command["command"] == "submit_job_result" && payloads(command["expect"]["events"], "check.finished").any? { |payload| payload["result"] == "failed" } }
    completion = failed["expect"]["events"].select { |event| event["command_id"] == first["key"] }
    assert_equal %w[task.contract_changed hold.opened], completion.map { |event| event["type"] }, "RD-10: the change is kept and the task held"
    assert_equal "contract_incomplete", completion.last["payload"]["reason"]
    second = commands.select { |command| command["command"] == "complete_contract" }[1]
    assert_equal [ "pending", "hold.closed" ], [ second["expect"]["outcome"], types(second).first ], "L175: Complete contract first closes contract_incomplete"
    assert events.any? { |event| event["type"] == "task.ready" && event["command_id"] == second["key"] }
    draft = commands.find { |command| command["command"] == "draft_contract" }
    assert_equal [ { "kind" => "contract_draft" } ], payloads(draft["expect"]["events"], "job.queued")
    planner = commands.find { |command| command["command"] == "submit_job_result" && command["body"]["result"].key?("criteria") }
    assert_equal "pending", planner["expect"]["outcome"], "RE-6: the planner's result waits on the check"
    ready = events.find { |event| event["type"] == "task.ready" && event["command_id"] == planner["key"] }
    assert_equal planner["caller"], ready["actor_id"], "RE-3: the planner is the requester"
    assert commands.any? { |command| command["expect"]["steps_opened"].any? { |step| step["kind"] == "draft" } }, "SM-24"
  end

  def test_trace_17_lets_a_submit_through_once_saves_a_wording_and_waits_at_the_rerun_limit
    name = "17-submit-rule-rerun-and-override"
    commands = commands_of(name)
    events = all_events(Leverage::Contract.trace(name))
    rule = commands.first
    assert_equal [ "add_rule", "task.before_submit" ], [ rule["command"], rule["body"]["hook"] ]
    overridden = commands.index { |command| command["command"] == "override_check" }
    resend = commands[overridden + 1]
    assert_equal [ "submit", %w[task.submitted] ], [ resend["command"], types(resend) ], "L382: the stored result is reused and completes"
    versions = payloads(events, "check.queued").select { |payload| payload["hook"] == "task.before_submit" && payload["blocking"] }.map { |payload| payload["rule_version_id"] }.uniq
    assert_equal 2, versions.size, "L911: the checks before the save keep the first wording"
    held = commands.find { |command| command["expect"]["outcome"] == "pending" && types(command).include?("hold.opened") }
    assert_equal [ "rerun_limit", false ], [ payloads(held["expect"]["events"], "hold.opened").first["reason"], types(held).include?("job.queued") ], "RD-45"
    hashes = payloads(events, "check.queued").select { |payload| payload["blocking"] }.map { |payload| payload["input_hash"] }
    assert_equal 4, hashes.uniq.size, "one hash in round 0 and three distinct ones in round 1 before the limit"
    release = commands.find { |command| command["command"] == "override_check" && command["expect"]["events"].any? { |event| event["command_id"] == held["key"] } }
    assert_equal %w[check.overridden hold.closed inbox.resolved task.submitted], types(release), "RD-45: the override completes it in place"
    warn = commands.find { |command| command["command"] == "submit" && payloads(command["expect"]["events"], "check.queued").any? { |payload| !payload["blocking"] } }
    assert_equal %w[check.queued job.queued task.submitted], types(warn), "RC-16: a warn check lets the submit through"
    assert payloads(events, "check.finished").any? { |payload| payload["result"] == "failed" && payload["rule_version_id"].end_with?("_3") }
  end

  def test_trace_18_has_a_provisional_claim_the_claim_gate_hold_a_done_gate_and_each_end_of_a_waiting_command
    name = "18-claim-gate-done-gate-and-ends"
    commands = commands_of(name)
    events = all_events(Leverage::Contract.trace(name))
    claimed = events.find { |event| event["type"] == "task.claimed" }
    claim = commands.find { |command| command["key"] == claimed["command_id"] }
    assert_equal [ "claim", "pending" ], [ claim["command"], claim["expect"]["outcome"] ], "L390: a provisional claim"
    # Rule 11: the waiting command is cancelled first, then the task or the
    # review is taken away.
    release = commands.find { |command| command["command"] == "release" }
    assert_equal %w[check.finished job.withdrawn task.released], types(release), "SM-13"
    opened = events.find { |event| event["type"] == "hold.opened" && event["payload"]["reason"] == "claim_gate_failed" }
    assert opened, "L393"
    failed_seats = events.select { |event| event["type"] == "check.finished" && event["payload"]["hook"] == "task.before_claim" && event["payload"]["result"] == "failed" }.map { |event| event["payload"]["subject_id"] }
    assert_equal 3, failed_seats.uniq.size
    off = commands.find { |command| command["command"] == "disable_rule" && types(command).include?("hold.closed") }
    assert_equal "turn_rule_off", payloads(off["expect"]["events"], "inbox.resolved").first["choice"]
    review_failed = events.find { |event| event["type"] == "review.failed" }
    refute_nil review_failed["payload"]["failed_rule_check_id"], "SM-6"
    { "builder_lease_expiry" => "task.lease_expired", "review_lease_expiry" => "review.lease_expired", "cancel" => "task.cancelled" }.each do |command_name, type|
      ending = commands.select { |command| command["command"] == command_name }.last
      assert_equal [ "check.finished", "job.withdrawn", type ], types(ending), "rule 11: #{command_name}"
      assert_equal "withdrawn", payloads(ending["expect"]["events"], "check.finished").first["result"]
    end
    late = commands.select { |command| command["command"] == "submit_job_result" && command["expect"]["outcome"] == "refused" }
    assert_equal [ "invalid_state" ] * 2, late.map { |command| command["expect"]["refusal"]["code"] }, "RD-41: a withdrawn job's result"
    assert_equal "task_cancelled", commands.last["expect"]["refusal"]["code"], "L919"
  end

  def test_trace_19_installs_the_rules_and_shows_the_provider_rule_the_offline_orchestrator_and_jobs
    name = "19-provider-rule-offline-and-jobs"
    trace = Leverage::Contract.trace(name)
    commands = trace["commands"]
    events = all_events(trace)
    assert_equal [ "rule.created" ] * 7, types(commands.first)
    refused = commands.select { |command| command["command"] == "claim_review" && command["expect"]["outcome"] == "refused" }
    assert_equal [ "not_eligible" ] * 2, refused.map { |command| command["expect"]["refusal"]["code"] }
    applied = refused.map { |command| payloads(command["expect"]["events"], "check.finished").first }
    assert_equal [ %w[review.assign applied refused] ] * 2, applied.map { |payload| payload.values_at("hook", "result", "effect") }, "RD-12"
    cause = refused.first["expect"]["steps_opened"].first
    assert_equal [ "wait_review", "rule", "$rule:different_provider_review" ], cause.values_at("kind", "cause_kind", "cause_rule_id"), "RD-11"
    assert_empty refused.last["expect"]["steps_opened"], "RD-11: once per wait"
    providers = trace["setup"]["credentials"].to_h { |row| [ row["id"], row["provider"] ] }
    switched = events.find { |event| event["type"] == "credential.switched" && event["payload"]["job_id"].nil? }
    second = trace["setup"]["seats"].find { |seat| seat["role"] == "reviewer" && seat["provider"] == providers[switched["subject_id"]] }
    assert_includes refused.map { |command| command["caller"] }, second["id"], "L912: a provider reached by handoff"
    item = events.find { |event| event["type"] == "inbox.opened" && event["payload"]["kind"] == "no_reviewer_eligible" }
    timer = commands.find { |command| command["command"] == "reviewer_eligibility" }
    assert_equal [ item["subject_id"] ], timer["expect"]["events"].map { |event| event["subject_id"] }, "RD-51: resolved by the timer"
    released = commands.find { |command| command["command"] == "report_limit" && command["body"]["review_id"] }
    assert_equal %w[credential.limit_reached review.released inbox.opened], types(released), "L913"
    assert commands.any? { |command| command["command"] == "check_run_timeout" && types(command) == %w[job.timed_out job.requeued check.queued] }
    assert commands.any? { |command| command["command"] == "rerun_check" }
    offline = commands.select { |command| command["command"] == "orchestrator_offline" }
    assert_equal [ %w[inbox.opened], %w[inbox.resolved check.queued job.queued] ], offline.map { |command| types(command) }, "RD-16, RD-19"
    jobs = commands.select { |command| command["command"] == "report_job_limit" }
    assert_equal [ %w[credential.limit_reached credential.switched], %w[credential.limit_reached] ], jobs.map { |command| types(command) }, "RD-40"
  end

  def test_trace_20_routes_answers_overturns_and_resumes_the_build
    name = "20-questions-and-access"
    trace = Leverage::Contract.trace(name)
    events = all_events(trace)
    assert_equal %w[to_orchestrator to_orchestrator to_orchestrator to_orchestrator to_owner],
      payloads(events, "check.finished").map { |payload| payload["effect"] }
    assert_equal %w[record decision owner owner owner owner],
      payloads(events, "question.answered").map { |payload| payload["basis"] }
    assert_equal %w[question.overturned], events_of(name, "overturn_answer").first.map { |event| event["type"] }

    answered = commands_of(name).select { |command| types(command).include?("question.answered") }
    assert answered.any? { |command| command.dig("expect", "steps_opened").any? { |step| step["kind"] == "build" } }
    assert_equal %w[owner_question owner_question access], payloads(events, "hold.opened").map { |payload| payload["reason"] }
    assert_equal %w[answer answer answer mark_access_granted], payloads(events, "inbox.resolved").map { |payload| payload["choice"] }
    first = events_of(name, "question_job_queue_timeout").fetch(0)
    second = events_of(name, "question_job_run_timeout").fetch(0)
    assert_equal %w[job.timed_out job.requeued], first.map { |event| event["type"] }
    assert_equal first.first["subject_id"], first.last["subject_id"]
    refute_equal first.first["subject_id"], second.first["subject_id"], "DB-31: the retry gets its own job"
    assert_equal %w[job.timed_out hold.opened inbox.opened], second.map { |event| event["type"] }
  end

  def test_trace_21_applies_project_and_task_budgets_and_escalates_only_with_a_stronger_builder
    name = "21-money-projects-escalation"
    commands = commands_of(name)
    events = all_events(Leverage::Contract.trace(name))
    assert_equal %w[raise_cap change_budget resume_project],
      payloads(events, "inbox.resolved").map { |payload| payload["choice"] }
    job_cost = events_of(name, "submit_job_result").fetch(0)
    assert_equal "job", job_cost.find { |event| event["type"] == "cost.reported" }["subject_kind"]
    assert_equal [ "project_paused", "project_paused" ], payloads(job_cost, "hold.opened").map { |payload| payload["reason"] }
    assert_equal [ "task.changed", "hold.opened" ], events_of(name, "change_task_project").first.map { |event| event["type"] }
    assert_equal [ "task.changed", "hold.closed" ], events_of(name, "change_task_project").last.map { |event| event["type"] }
    assert_equal [ 2 ], payloads(events, "task.reassigned").map { |payload| payload["minimum_strength_rank"] }
    assert_equal 4, events.count { |event| event["type"] == "review.failed" }
    assert_equal [ "not_eligible" ] * 3, commands.filter_map { |command| command.dig("expect", "refusal", "code") }
    # PRD L130: the previous builder is free, so the failed review alone
    # would give it a fresh lease (L91); the escalation is what sends the
    # task to Ready, and task.reassigned is the event steps.json gives that
    # move (wait_ready, "an escalation sends the task to Ready").
    escalation = commands.find { |command| types(command).include?("task.reassigned") }
    reassigned = escalation["expect"]["events"].find { |event| event["type"] == "task.reassigned" }
    assert_equal [ [ "wait_ready", reassigned["ref"] ] ],
      escalation["expect"]["steps_opened"].map { |step| [ step["kind"], step["opening_event_id"] ] }
  end

  # README, Golden traces, Order: a job result writes job.finished, the
  # check's check.finished, then cost.reported. An approval job is the
  # attempt of the approval policy's check (jobs.json), so its result keeps
  # the order of every other check job's, as traces 03 and 04 have it.
  def test_a_check_jobs_result_writes_its_check_before_its_cost
    seen = 0
    NAMES.each do |name|
      trace = Leverage::Contract.trace(name)
      checks = all_events(trace).select { |event| event["type"] == "check.queued" }
        .to_h { |event| [ event["payload"]["job_id"], event["subject_id"] ] }
      trace["commands"].each_with_index do |command, index|
        next unless command["command"] == "submit_job_result" && command["expect"]["outcome"] == "completed"

        events = command["expect"]["events"]
        check = checks[events.first["subject_id"]] or next
        where = "#{name} command #{index + 1}"
        assert_equal %w[job.finished check.finished cost.reported], events.first(3).map { |event| event["type"] }, where
        assert_equal check, events[1]["subject_id"], "#{where}: the check whose attempt the job is"
        seen += 1
      end
    end
    assert_operator seen, :>=, 7, "trace 22's approval results are among them"
  end

  def test_trace_22_keeps_or_replaces_the_retained_lease_and_never_reopens_an_errored_approval
    name = "22-finishing-edges"
    events = all_events(Leverage::Contract.trace(name))
    assert_equal [ "$seat:builder", "$seat:builder" ],
      payloads(events_of(name, "offer_task_again").flatten, "hold.closed").map { |payload| payload["lease_seat_id"] }
    mark = events_of(name, "mark_action_done")
    assert_equal %w[action.marked_done hold.closed inbox.resolved], mark.first.map { |event| event["type"] }
    assert_nil payloads(mark.first, "hold.closed").first["lease_seat_id"]
    assert_equal %w[action.marked_done hold.closed task.done inbox.resolved], mark.last.map { |event| event["type"] }
    waivers = events_of(name, "waive_action")
    assert_equal [ nil, nil ], payloads(waivers.first(2).flatten, "action.waived").map { |payload| payload["lease_seat_id"] }
    assert_equal %w[action.waived task.done hold.closed inbox.resolved], waivers.last.map { |event| event["type"] }
    rework = events_of(name, "return_for_rework").first
    assert_equal "$seat:builder", payloads(rework, "task.returned_for_rework").first["lease_seat_id"]
    assert_equal [ %w[action.stopped hold.opened inbox.opened], %w[action.overturn_recorded], [] ].sort,
      events_of(name, "overturn_approval").map { |group| group.map { |event| event["type"] } }.sort
    assert_equal [ %w[inbox.opened], %w[inbox.resolved] ],
      events_of(name, "orchestrator_offline").map { |group| group.map { |event| event["type"] } }
    assert_equal [ "error" ], payloads(events_of(name, "check_queue_timeout").flatten, "check.finished").map { |payload| payload["result"] }
    assert_includes events.map { |event| event["type"] }, "action.revoked"
  end

  def test_trace_23_changes_a_live_brief_and_the_claim_order_and_retains_deleted_tasks_in_the_log
    name = "23-owner-housekeeping"
    commands = commands_of(name)
    events = all_events(Leverage::Contract.trace(name))
    assert_equal [ 1, 1, 2, 2 ], payloads(events, "brief.changed").map { |payload| payload["brief_version"] }
    assert_includes commands.filter_map { |command| command.dig("expect", "refusal", "code") }, "briefing_changed"
    created = events.select { |event| event["type"] == "task.created" }.map { |event| event["task_id"] }
    first_claim = commands.find { |command| command["command"] == "claim" }
    assert_equal created.last, first_claim.dig("expect", "events", 0, "task_id"), "the newer task was raised to high priority"
    timer = events.find { |event| event["type"] == "task.lease_expired" }
    assert_equal 300, seconds(timer["effective_at"]) - seconds(first_claim["at"])
    deleted = events.select { |event| event["type"] == "content.deleted" }
    assert_equal [ created.last, nil, created.first ], deleted.map { |event| event["task_id"] }
  end

  # A helper report runs the rows of the work it names, as a verdict runs
  # pass_review or fail_review (README, The state table): one that names a
  # job runs report_job_limit or report_job_signed_out (milestone 4 plan
  # section 2.1, the twenty entries; the controller picks it from the
  # body), and one that names none runs milestone 3's report_limit or
  # report_signed_out, which answer 404 for a job (HE-33).
  def test_a_report_that_names_a_job_runs_the_job_report
    jobs = 0
    traces.each do |name, trace|
      trace["commands"].each_with_index do |command, index|
        next unless %w[report_limit report_signed_out].include?(command["operation_id"])

        job = command["body"]["job_id"]
        expected = job ? command["operation_id"].sub("report_", "report_job_") : command["operation_id"]
        assert_equal expected, command["command"], "#{name} command #{index + 1}"
        jobs += 1 if job
      end
    end
    assert_operator jobs, :>=, 2, "trace 19 reports a job's limit with and without a candidate"
  end

  # A check's input hash stands for its hook's hashed inputs (hooks.json
  # hashed_inputs; README, A check's identity), so within a trace one set
  # of inputs carries one digest, two sets two digests, and every attempt
  # of a check the digest of its first. The inputs are read back from the
  # trace as Leverage::HookInputs reads them from the rows: the request of
  # the command that first writes the check, and the task's contract
  # version, live criteria, their states and every evidence attached, in
  # order, before that command. It holds for every trace.
  def test_one_set_of_hashed_inputs_carries_one_digest
    NAMES.each { |name| assert_equal [], input_hash_failures(Leverage::Contract.trace(name)), name }
  end

  # Trace 07's two checks at task.before_ready hash one request, and carry
  # the engine's own hash of it: Gating.input_hash of the goal, details,
  # criteria and actions the request sends (Leverage::HookInputs).
  def test_trace_07_carries_the_real_digest_of_its_request
    commands = commands_of("07-pending-gate-check-error-override")
    request = commands.find { |command| command["command"] == "complete_contract" }
    digests = request["expect"]["events"].select { |event| event["type"].start_with?("check.") }
      .map { |event| event["payload"]["input_hash"] }
    body = request["body"]
    inputs = { "goal" => body["goal"], "details" => body["details"],
               "criteria" => body["criteria"].map { |criterion| criterion.slice("text", "kind") },
               "actions" => body["actions"].map { |action| action.slice("kind", "description") } }
    assert_equal 2, digests.size
    assert_equal [ Leverage::Gating.input_hash(hook: "task.before_ready", inputs: inputs) ] * 2, digests
  end

  def input_hash_failures(trace)
    requests = trace["commands"].select { |command| command["key"] }.to_h { |command| [ command["key"], command ] }
    rows = TaskRows.new
    first = {}
    digests = Hash.new { |hash, key| hash[key] = Set.new }
    inputs = Hash.new { |hash, key| hash[key] = Set.new }
    failures = []
    trace["commands"].each_with_index do |command, index|
      command["expect"]["events"].select { |event| %w[check.queued check.finished].include?(event["type"]) }.each do |event|
        check = event["subject_id"]
        digest = event["payload"]["input_hash"]
        if first.key?(check)
          failures << "command #{index + 1}: #{check} carries another digest than its first" unless first[check] == digest
          next
        end
        first[check] = digest
        request = requests[event["command_id"]] or next
        hashed = rows.hashed_inputs(event, request["body"]) or next
        digests[hashed] << digest
        inputs[[ event["payload"]["hook"], digest ]] << hashed
      end
      rows.apply(command)
    end
    digests.each { |hashed, set| failures << "#{hashed.first}: one set of inputs carries #{set.size} digests" if set.size > 1 }
    inputs.each { |(hook, digest), set| failures << "#{hook}: #{digest[0, 8]} is the digest of #{set.size} sets of inputs" if set.size > 1 }
    failures
  end

  # What the trace has written so far of each task's contract version,
  # criteria and evidence: the rows HookInputs hashes.
  class TaskRows
    def initialize
      @version = {}
      @criteria = Hash.new { |hash, key| hash[key] = [] }
      @states = {}
      @evidence = Hash.new { |hash, key| hash[key] = [] }
    end

    # [hook, inputs] for the check event's hook, as the request body and
    # the rows before its command give them; nil for a hook not read here.
    def hashed_inputs(event, body)
      payload = event["payload"]
      task = event["task_id"]
      inputs = case payload["hook"]
      when "task.before_ready" then contract(body["result"] || body)
      when "task.before_claim" then [ @version[task], payload["subject_id"] ]
      when "task.before_submit"
        [ @version[task], @criteria[task].map { |id| [ id, @states[id], @evidence[id] ] }, body["handoff_note"] ]
      when "task.before_done"
        [ @version[task], body["verdict"], body["notes"], @criteria[task].reject { |id| @evidence[id].empty? }.map { |id| [ id, @evidence[id] ] } ]
      when "review.assign" then [ payload["subject_id"] ]
      end
      inputs && [ payload["hook"], inputs ]
    end

    def apply(command)
      command["expect"]["events"].each do |event|
        payload = event["payload"]
        task = event["task_id"]
        case event["type"]
        when "task.contract_changed"
          @version[task] = payload["contract_version"]
          @criteria[task] = @criteria[task] - payload["removed_criterion_ids"] + payload["added_criterion_ids"]
          (payload["added_criterion_ids"] + payload["reset_criterion_ids"]).each { |id| @states[id] = "open" }
        when "criterion.passed" then @states[event["subject_id"]] = "passed"
        when "criterion.reopened" then @states[event["subject_id"]] = "open"
        when "evidence.attached" then @evidence[payload["criterion_id"]] << [ payload["kind"], command["body"].dig("evidence", "value") ]
        end
      end
    end

    private

    def contract(body)
      [ body["goal"], body["details"], Array(body["criteria"]).map { |criterion| criterion.values_at("text", "kind") },
        Array(body["actions"]).map { |action| action.values_at("kind", "description") } ]
    end
  end
end
