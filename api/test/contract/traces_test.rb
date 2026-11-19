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

  # The eight traces plan IF-33 names.
  NAMES = %w[
    01-happy-path 02-failed-review-rework 03-stop-rework-pass-approve-done
    04-two-actions-custom-rule 05-limit-handoff 06-signed-out-hold-verify
    07-pending-gate-check-error-override 08-lease-expiry-and-cancel
  ].freeze

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
      odd = command["expect"]["events"].map { |event| event["type"] }.reject { |type| type.start_with?("check.", "job.") }
      fail_state(index, "a pending command writes only rule check and job events, not #{odd}") unless odd.empty?
      @pending[command["key"]] = { task: target, names: command_names(command), from: @state[target], index: index }
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
        matched = own.group_by { |event| event["task_id"] }.map do |task, group|
          match(index, command_names(command), task, task ? @state[task] : nil, group, target)
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
        unless cause && cause["type"] == "check.finished"
          fail_state(index, "#{event["ref"]} completes #{key}: its cause_id names the check.finished event")
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
      names.flat_map { |name| @rows.fetch(name, []) }.select { |row| row["from"].nil? || row["from"] == state }
    end

    # Finds the rows of names, from state, that the events of one task fit,
    # applies the state they lead to, and returns them. Every row's own
    # events must be written; every event written must belong to a matched
    # row or be a side event; the state the events lead to must be the
    # rows' to-state.
    def match(index, names, task, state, events, target)
      types = events.map { |event| event["type"] }
      fresh = events.any? { |event| event["payload"][LEASE_FIELD] }
      observed = observe(state, events)
      groups = state_rows(names, state).reject { |row| row["refusal"] }.group_by { |row| [ row["command"], row["from"] ] }
      kept = groups.values.flat_map { |rows| pick(rows, types, fresh, state, observed) }
      allowed = kept.flat_map { |row| row["events"] + (row["conditional_events"] + row["side_events"]).map { |entry| entry["event"] } }.to_set
      stray = types.reject { |type| allowed.include?(type) || @side_types.include?(type) }
      fail_state(index, "#{task.inspect}: no matched row writes #{stray.uniq} (rows: #{kept.map { |row| row["command"] }.uniq})") unless stray.empty?
      if task
        if kept.any? { |row| row["from"] || row["to"] } || observed != state
          unless kept.any? { |row| (row["from"] || row["to"]) && (row["to"] || row["from"]) == observed }
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

  def test_the_eight_traces_of_if_33_exist_and_no_other
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
      shipped.each { |key| assert_equal 1, rules.count { |rule| rule["key"] == key && rule["origin"] == "shipped" }, "#{name}: #{key}" }
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
      trace["commands"].each_with_index do |command, index|
        command["expect"]["events"].each do |event|
          where = "#{name} command #{index + 1} #{event["ref"]}"
          case command["caller"]
          when "app"
            assert_equal [ "app", nil, nil ], event.values_at("actor_kind", "actor_id", "command_id"), "#{where}: the server's own events carry no actor id and no key"
          when /\A\$helper:/
            assert_equal [ "app", command["caller"], command["key"] ], event.values_at("actor_kind", "actor_id", "command_id"), "#{where}: a helper report's events (plan IF-37)"
          else
            if event["actor_kind"] == "app"
              assert_nil event["actor_id"], where
            else
              assert_equal [ SYMBOL.match(command["caller"])[1] == "user" ? "owner" : "seat", command["caller"] ], event.values_at("actor_kind", "actor_id"), where
            end
            refute_nil event["command_id"], "#{where}: only events of the server's own requests carry no key" if event["actor_kind"] != "app"
          end
        end
      end
    end
  end

  # One job row per attempt (plan DB-31): a check queued again runs on a new
  # job, and job.requeued is written on the job it replaces.
  def test_each_attempt_of_a_check_runs_on_a_job_of_its_own
    traces.each do |name, trace|
      jobs_by_check = Hash.new { |hash, key| hash[key] = [] }
      all_events(trace).each do |event|
        case event["type"]
        when "check.queued"
          earlier = jobs_by_check[event["subject_id"]]
          refute_includes earlier, event.dig("payload", "job_id"), "#{name} #{event["ref"]}: an attempt reuses a job"
          earlier << event.dig("payload", "job_id")
        when "job.requeued"
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
end
