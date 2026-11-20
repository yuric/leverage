require "digest"
require "json"
require "set"
require "time"

# Runs a golden trace through the engine (PRD test 8; milestone 2 plan TS-8)
# and compares what it writes with what the trace expects, event for event
# and step row for step row.
#
# The trace's setup (the owner, the helper, the credentials, the seats and
# the projects, with the ids TraceBinder gives their symbols) is built by
# Scenario#seed, which appends the setup's events through EventLog; only the
# trace's commands go through Transitions.apply.
#
# The engine makes its own ids and reads its own clock (EN-18: no clock
# stub), so a trace's symbols are matched, not bound in advance:
#
#   $kind:name  The setup's rows and the keys have TraceBinder's ids. Any
#               other symbol ($task:1, $criterion:t1_copy, $review:t1_r0,
#               $hold:t1_rounds_1) is bound to the id the engine wrote
#               where the trace first shows it, and must then be that id
#               everywhere; two symbols never share an id.
#   @event:n    The id of the n-th event the engine wrote for the trace.
#   @t:s        Bound to the database time where first seen. A time seen
#               again must be the same instant, and the trace's order of
#               times must be the engine's (s1 < s2 exactly when t1 < t2),
#               so the events of one command share at and effective_at, a
#               timer's events carry the due time, and nothing runs
#               backwards.
#
# Times a request sends (milestone 3: a report's reset_at and observed_at)
# are compared by the engine with its clock, so they are resolved before
# the command runs, not matched after it. A bound @t is its instant. An
# unbound one before the command's own @t is placed strictly between the
# instants of the nearest bound times around it (the database's now
# standing for the command's own @t), keeping the trace's order. An
# unbound one after the command's own @t is a future time, FUTURE + s
# seconds, so future times keep their order and the clock never reaches
# one. The trace then reaches a future time without a clock stub, as a
# lease reaches its due time (EN-18): before a command at @t:s, every
# future @t:n with n <= s is moved to the database's now, each
# credential whose limited_until is that time with it, and @t:n is bound
# again to the new instant (pass_times). So a reset passes between two
# commands, and a timer due at a reset carries it as its effective time.
#
# Helper requests ($helper_request:name). A command that queues one
# (verify_credential, sign_in_again) shows no event with its id, so a
# symbol of that kind first sent in a request is bound to the newest
# unfinished request of the workspace that no symbol names yet.
#
# Timers. A timer command (caller app) cannot wait for a due time, so its
# lease is put at its due time first with Scenario#make_due (EN-18). Before
# that, the lease's arithmetic is checked (L116-L120): the lease is running,
# not paused; in the trace, the timer's due @t is one lease length after
# the @t of the lease's last grant (task.claimed, review.started, an event
# naming lease_seat_id, or a heartbeat that completed); and in the engine,
# the row's lease_due_at is one lease length after that grant's own time.
# A hold on the task between the grant and the timer whose reason pauses
# the lease clock (the registry's lease_clock "pauses") would pause it,
# which this runner does not model: it fails the trace instead of passing
# it unchecked. A hold whose clock runs (seat_paused, credential_limit:
# L116, trace 14) leaves the lease as it was. When
# the next command comes at the same time (a late call, L913), the timer is
# what that command applies first (Timers.apply_due), and the two are
# compared together; otherwise it is run as the sweep runs it, as a command
# of the app with no params.
#
# Briefing hashes. The traces carry placeholders ("briefing-hash-t1_ack_30");
# an acknowledgement sends the hash of the briefing the seat would read at
# that point, Briefing.hash_for(task or review, seat) (WP3's choice 5).
#
# Steps are compared as they are just after the command that opens them:
# the criterion back-fill (PRD rule 5) later gives an open build row its
# criterion, which the trace cannot show (step_closed has no subject; the
# TS8-check's note).
class TraceRunner
  T = Leverage::Transitions

  SYMBOL = /\A\$([a-z][a-z_]*):[a-z0-9][a-z0-9_]*\z/
  EVENT = /\A@event:([1-9][0-9]*)\z/
  TIME = /\A@t:(-?[0-9]+)\z/
  ACKNOWLEDGEMENTS = { "acknowledge_briefing" => Task, "acknowledge_review_briefing" => Review }.freeze
  CALLERS = { "user" => "owner", "seat" => "seat", "helper" => "helper" }.freeze
  EVENT_FIELDS = %w[type schema_version actor_kind subject_kind round].freeze
  EVENT_IDS = %w[actor_id project_id task_id subject_id].freeze
  STEP_FIELDS = %w[step_class round subject_kind cause_kind].freeze
  STEP_IDS = %w[task_id subject_id seat_id cause_rule_id].freeze
  HELPER_REQUEST = "helper_request".freeze
  UNFINISHED_REQUESTS = %w[queued picked_up].freeze
  FUTURE = 365 * 24 * 3600
  LEASE_ENDS = %w[task.lease_expired review.lease_expired].freeze
  # The hold reasons that pause a lease clock (the registry's lease_clock).
  PAUSING = Leverage::Contract.registry.fetch("hold_reasons")
    .select { |reason| reason.fetch("lease_clock") == "pauses" }.map { |reason| reason.fetch("reason") }.freeze

  attr_reader :name, :trace, :scenario, :failures, :setup_seq

  # trace: the trace itself, when a test runs a changed copy of one.
  # namespace: TraceBinder's, for a run whose rows are committed and stay
  # in the worker's database, so that its ids meet no later run's.
  def initialize(name, trace: nil, namespace: Leverage::Contract::TraceBinder::NAMESPACE)
    @name = name
    @trace = trace || Leverage::Contract.trace(name)
    @binder = Leverage::Contract::TraceBinder.new(start: Time.utc(2026, 1, 1), namespace: namespace)
    @ids = {}
    @symbols = {}
    @events = {}
    @times = {}
    @leases = {}
    @future = Set.new
    @failures = []
  end

  def workspace_id = scenario.workspace_id

  # The trace's @t seconds bound to an instant the engine wrote, or nil: a
  # length the engine measured in its own clock is read back in the
  # trace's (recovery_time_test.rb).
  def trace_seconds(instant)
    instant = Time.iso8601(instant) if instant.is_a?(String)
    @times.key(instant)
  end

  # Runs the first limit commands (all by default) and returns self; the
  # disagreements are in failures.
  def run(limit = trace.fetch("commands").size)
    seed
    commands = trace.fetch("commands").first(limit)
    index = 0
    while index < commands.size
      command = commands[index]
      following = commands[index + 1]
      pass_times(command, index)
      if command.fetch("caller") == "app"
        make_due(command, index)
        if following && following.fetch("caller") != "app" && following.fetch("at") == command.fetch("at")
          run_command(following, index + 1, timer: [ command, index ])
          index += 2
        else
          run_timer(command, index)
          index += 1
        end
      else
        run_command(command, index)
        index += 1
      end
    end
    self
  end

  private

  # --- setup -------------------------------------------------------------

  def seed
    setup = trace.fetch("setup")
    %w[users helpers credentials seats projects].each do |table|
      Array(setup[table]).each { |row| bind_symbol(row.fetch("id"), @binder.id(row.fetch("id")), "setup") }
    end
    @scenario = Scenario.new
    scenario.seed(@binder.bind(setup))
    added_but_signed_out(setup)
    @setup_seq = scenario.workspace.reload.last_seq
  end

  # A setup login that is signed out was added before the trace starts and
  # signed out since (traces 12 and 13: Sign in again is for an added login,
  # HE-36). Scenario#seed makes a signed-out setup credential one whose add
  # is still running (no last_verified_at), so it is given the setup's
  # start as the time its checks passed. A credential row is not a replay
  # column and the setup's events are not audited.
  def added_but_signed_out(setup)
    ids = Array(setup["credentials"]).select { |row| row.fetch("state") == "signed_out" }
      .map { |row| @binder.id(row.fetch("id")) }
    Credential.where(workspace_id: workspace_id, id: ids).update_all(last_verified_at: @binder.start)
  end

  # --- running -----------------------------------------------------------

  def run_command(command, index, timer: nil)
    where = label(command, index)
    caller_kind, caller_id = caller_of(command)
    params = request_params(command, caller_id)
    request = T::Request.new(command: command.fetch("command"), workspace_id: workspace_id, caller_kind: caller_kind,
      caller_id: caller_id, key: command["key"] && key_id(command["key"]), request_hash: request_hash(params),
      params: params)
    expected = [ timer, [ command, index ] ].compact
    apply_and_compare(request, expected, where)
  end

  def run_timer(command, index)
    request = T::Request.new(command: command.fetch("command"), workspace_id: workspace_id, caller_kind: nil,
      caller_id: nil, key: nil, request_hash: nil, params: {})
    apply_and_compare(request, [ [ command, index ] ], label(command, index))
  end

  def apply_and_compare(request, expected, where)
    before = scenario.workspace.reload.last_seq
    started = scenario.database_now
    outcome = begin
      T.apply(request)
    rescue T::NotFound, T::Invalid, Leverage::Idempotency::KeyReused => error
      fail_at(where, "raised #{error.class}: #{error.message}")
      return
    end
    note_heartbeat(request, outcome, expected.last.first, started..scenario.database_now)
    written = Event.where(workspace_id: workspace_id).where("seq > ?", before).order(:seq).to_a
    command, = expected.last
    compare_outcome(command.fetch("expect"), outcome, where)
    compare_events(expected.flat_map { |item, _| item.fetch("expect").fetch("events") }, written, where)
    compare_steps(expected.map { |item, _| item.fetch("expect") }, written, where)
    compare_result(command.fetch("expect")["result_fields"], outcome, where)
  end

  # A timer's subject is put at its due time: the task of each
  # task.lease_expired and the review of each review.lease_expired it
  # expects.
  # A credential hold's release is due at a reset that pass_times has
  # already moved, or at once: nothing more to move for it.
  def make_due(command, index)
    command.fetch("expect").fetch("events").each do |event|
      type = event.fetch("type")
      next unless LEASE_ENDS.include?(type)

      record =
        case type
        when "task.lease_expired" then Task.find_by(id: @ids[event.fetch("task_id")])
        when "review.lease_expired" then Review.find_by(id: @ids[event.fetch("subject_id")])
        end
      if record
        check_lease(record, event, label(command, index))
        scenario.make_due(record, at: scenario.database_now)
      else
        fail_at(label(command, index), "cannot find what #{event.fetch("type")} expires")
      end
    end
  end

  def caller_of(command)
    caller = command.fetch("caller")
    return [ nil, nil ] if caller == "app"

    [ CALLERS.fetch(SYMBOL.match(caller)[1]), bound(caller) ]
  end

  def request_params(command, caller_id)
    @command_seconds = seconds(command.fetch("at"))
    params = resolve(command.fetch("path_params")).merge(resolve(command.fetch("body")))
    subject_class = ACKNOWLEDGEMENTS[command.fetch("command")]
    if subject_class && params.key?("briefing_hash")
      subject = subject_class.find_by(id: params["id"])
      seat = Seat.find_by(id: caller_id)
      params["briefing_hash"] = Leverage::Briefing.hash_for(subject, seat) if subject && seat
    end
    params
  end

  def request_hash(params) = Digest::SHA256.hexdigest(JSON.generate(params))

  # A request's values with every symbol replaced by the id bound to it.
  def resolve(value)
    case value
    when Hash then value.to_h { |key, item| [ key, resolve(item) ] }
    when Array then value.map { |item| resolve(item) }
    when SYMBOL then bound(value)
    when TIME then sent_time(seconds(value)).utc.iso8601(6)
    else value
    end
  end

  def bound(symbol)
    return key_id(symbol) if symbol.start_with?("$key:")

    bind_helper_request(symbol) if SYMBOL.match(symbol)[1] == HELPER_REQUEST && !@ids.key?(symbol)
    @ids.fetch(symbol) { raise ArgumentError, "#{name}: #{symbol} is sent before the trace shows its id" }
  end

  def bind_helper_request(symbol)
    request = HelperRequest.where(workspace_id: workspace_id, state: UNFINISHED_REQUESTS)
      .where.not(id: @symbols.keys).order(created_at: :desc, id: :desc).first
    bind_symbol(symbol, request.id, "#{symbol}, the newest unfinished helper request") if request
  end

  # --- times a request sends ---------------------------------------------

  def seconds(link) = Integer(TIME.match(link)[1], 10)

  # The instant a request sends for @t:n (see the class comment).
  def sent_time(number)
    return @times.fetch(number) if @times.key?(number)

    instant = if number > @command_seconds
      @future_base ||= Time.at(scenario.database_now.to_i + FUTURE).utc
      @future << number
      @future_base + number
    else
      between(number)
    end
    @times[number] = instant
  end

  # An instant for an unbound @t:n before the command's own @t, strictly
  # between the nearest bound times around it, at its share of the gap;
  # the database's now stands for the command's own @t.
  def between(number)
    now = scenario.database_now
    present = @times.reject { |key, _| @future.include?(key) }
    below = present.select { |key, _| key < number }.max_by(&:first)
    above = present.select { |key, _| key > number && key < @command_seconds }.min_by(&:first) || [ @command_seconds, now ]
    below ||= [ number - 1, above.last - (above.first - number + 1) ]
    share = Rational(number - below.first, above.first - below.first)
    (below.last + (above.last - below.last) * share).round(6)
  end

  # Before a command at @t:s, every future time at or before s passes: the
  # credentials whose reset it is are put at the database's now, and the
  # time is bound again to that instant (see the class comment).
  def pass_times(command, index)
    reached = seconds(command.fetch("at"))
    @future.select { |number| number <= reached }.sort.each do |number|
      now = scenario.database_now
      Credential.where(workspace_id: workspace_id, limited_until: @times.fetch(number)).update_all(limited_until: now)
      @future.delete(number)
      @times.delete(number)
      match_time("@t:#{number}", now, label(command, index), "a reset passing")
    end
  end

  def key_id(symbol) = @binder.id(symbol)

  # --- comparing ---------------------------------------------------------

  def compare_outcome(expect, outcome, where)
    actual = outcome.outcome.to_s
    fail_at(where, "outcome #{actual}, the trace expects #{expect.fetch("outcome")}") if actual != expect.fetch("outcome")
    refusal = expect.fetch("refusal")
    actual_refusal = outcome.refusal && { "code" => outcome.refusal.code, "rule_id" => outcome.refusal.rule_id }
    return if refusal.nil? && actual_refusal.nil?
    return if refusal && actual_refusal && refusal.fetch("code") == actual_refusal.fetch("code") &&
      match_id(refusal.fetch("rule_id"), actual_refusal.fetch("rule_id"), where, "refusal rule_id")

    fail_at(where, "refusal #{actual_refusal.inspect}, the trace expects #{refusal.inspect}")
  end

  def compare_events(expected, written, where)
    if expected.size != written.size
      fail_at(where, "wrote #{written.map(&:type)}, the trace expects #{expected.map { |event| event.fetch("type") }}")
      return
    end
    expected.zip(written).each { |event, row| compare_event(event, row, where) }
  end

  def compare_event(event, row, where)
    ref = event.fetch("ref")
    @events[Integer(EVENT.match(ref)[1], 10)] = row.id
    at = "#{where}, #{ref} (#{event.fetch("type")})"
    EVENT_FIELDS.each do |field|
      fail_at(at, "#{field} #{row[field].inspect}, expected #{event.fetch(field).inspect}") if row[field] != event.fetch(field)
    end
    EVENT_IDS.each { |field| match_id(event.fetch(field), row[field], at, field) }
    match_event(event.fetch("cause_id"), row.cause_id, at, "cause_id")
    command_id = event.fetch("command_id")
    fail_at(at, "command_id #{row.command_id.inspect}, expected #{command_id.inspect}") if (command_id && key_id(command_id)) != row.command_id
    match_time(event.fetch("at"), row.at, at, "at")
    match_time(event.fetch("effective_at"), row.effective_at, at, "effective_at")
    match_value(event.fetch("payload"), row.payload, at, "payload")
    note_lease(event, row)
  end

  # The steps the commands open and close, as the rows are now.
  def compare_steps(expects, written, where)
    ids = written.map(&:id)
    opened = TaskStep.where(workspace_id: workspace_id, opening_event_id: ids).to_a
    closed = TaskStep.where(workspace_id: workspace_id, closing_event_id: ids).to_a
    expected_opened = expects.flat_map { |expect| expect.fetch("steps_opened") }
    expected_closed = expects.flat_map { |expect| expect.fetch("steps_closed") }
    compare_opened(expected_opened, opened, where)
    compare_closed(expected_closed, closed, where)
  end

  def compare_opened(expected, opened, where)
    unmatched = opened.dup
    expected.each do |step|
      event_id = @events[Integer(EVENT.match(step.fetch("opening_event_id"))[1], 10)]
      row = unmatched.find { |candidate| candidate.opening_event_id == event_id && candidate.kind == step.fetch("kind") }
      at = "#{where}, step #{step.fetch("kind")} opened at #{step.fetch("opening_event_id")}"
      unless row
        fail_at(at, "no such row (opened: #{opened.map(&:kind)})")
        next
      end
      unmatched.delete(row)
      STEP_FIELDS.each do |field|
        fail_at(at, "#{field} #{row[field].inspect}, expected #{step.fetch(field).inspect}") if row[field] != step.fetch(field)
      end
      STEP_IDS.each { |field| match_id(step.fetch(field), row[field], at, field) }
    end
    unmatched.each { |row| fail_at(where, "opened a #{row.kind} step the trace does not list") }
  end

  def compare_closed(expected, closed, where)
    wanted = expected.map do |step|
      [ @ids[step.fetch("task_id")], step.fetch("kind"),
        @events[Integer(EVENT.match(step.fetch("closing_event_id"))[1], 10)] ]
    end
    actual = closed.map { |row| [ row.task_id, row.kind, row.closing_event_id ] }
    return if wanted.sort_by(&:to_s) == actual.sort_by(&:to_s)

    fail_at(where, "closed #{closed.map(&:kind)}, the trace expects #{expected.map { |step| step.fetch("kind") }}")
  end

  def compare_result(fields, outcome, where)
    return unless fields

    result = outcome.result || {}
    fields.each { |key, value| match_value(value, result[key], where, "result #{key}") }
  end

  # --- lease arithmetic --------------------------------------------------

  # The last grant of each lease, by the engine's id of its task or review:
  # the trace's @t seconds, the engine's time (a Range for a heartbeat,
  # which writes no event: the database clock before and after it), and
  # whether a hold opened or closed on the task since.
  def grant_lease(id, task_id, seconds, at)
    @leases[id] = { task_id: task_id, seconds: seconds, at: at, interrupted: false }
  end

  def note_lease(event, row)
    seconds = Integer(TIME.match(event.fetch("effective_at"))[1], 10)
    case row.type
    when Leverage::Leases::BUILDER_GRANT then grant_lease(row.task_id, row.task_id, seconds, row.effective_at)
    when "review.started" then grant_lease(row.subject_id, row.task_id, seconds, row.effective_at)
    when "hold.opened", "hold.closed"
      if PAUSING.include?(row.payload["reason"])
        @leases.each_value { |lease| lease[:interrupted] = true if lease[:task_id] == row.task_id }
      end
    end
    return unless row.payload.is_a?(Hash) && row.payload["lease_seat_id"]

    grant_lease(row.task_id, row.task_id, seconds, row.effective_at)
  end

  HEARTBEATS = { "heartbeat" => Task, "heartbeat_review" => Review }.freeze

  def note_heartbeat(request, outcome, command, clock)
    model = HEARTBEATS[request.command]
    return unless model && outcome.completed?

    record = model.find_by(id: request.params["id"])
    return unless record

    task_id = record.is_a?(Task) ? record.id : record.task_id
    grant_lease(record.id, task_id, Integer(TIME.match(command.fetch("at"))[1], 10), clock)
  end

  def check_lease(record, event, where)
    type = event.fetch("type")
    length = scenario.workspace.reload.lease_length_seconds
    record.reload
    if record.lease_time_left_while_paused
      fail_at(where, "#{type} ends a paused lease (#{record.lease_time_left_while_paused} s left), which no timer does")
      return
    end
    grant = @leases[record.id]
    return fail_at(where, "#{type}: no lease grant comes before it") unless grant
    if grant[:interrupted]
      return fail_at(where, "#{type}: a hold that pauses the lease opened or closed on the task since its grant at " \
                            "@t:#{grant[:seconds]}; the runner does not model a paused lease")
    end

    due = Integer(TIME.match(event.fetch("effective_at"))[1], 10)
    unless due - grant[:seconds] == length
      fail_at(where, "#{type}: the trace's lease runs #{due - grant[:seconds]} s, from its grant at @t:#{grant[:seconds]} " \
                     "to @t:#{due}; the lease length is #{length} s")
    end
    granted = grant[:at]
    actual = record.lease_due_at
    on_time = if actual.nil?
      false
    elsif granted.is_a?(Range)
      (granted.begin + length..granted.end + length).cover?(actual)
    else
      (actual - (granted + length)).abs < 0.000_001
    end
    return if on_time

    fail_at(where, "#{type}: the engine's lease is due #{actual&.iso8601(6).inspect}, not one lease length " \
                   "(#{length} s) after its grant at #{granted.is_a?(Range) ? granted.begin.iso8601(6) : granted.iso8601(6)}")
  end

  # --- matching symbols, event links and times ---------------------------

  def match_value(expected, actual, where, path)
    case expected
    when Hash
      unless actual.is_a?(Hash) && actual.keys.sort == expected.keys.sort
        fail_at(where, "#{path} #{actual.inspect}, expected #{expected.inspect}")
        return
      end
      expected.each { |key, value| match_value(value, actual[key], where, "#{path}.#{key}") }
    when Array
      unless actual.is_a?(Array) && actual.size == expected.size
        fail_at(where, "#{path} #{actual.inspect}, expected #{expected.inspect}")
        return
      end
      expected.zip(actual).each_with_index { |(value, item), index| match_value(value, item, where, "#{path}[#{index}]") }
    when SYMBOL then match_id(expected, actual, where, path)
    when EVENT then match_event(expected, actual, where, path)
    when TIME then match_time(expected, actual.is_a?(String) ? Time.iso8601(actual) : actual, where, path)
    else
      fail_at(where, "#{path} #{actual.inspect}, expected #{expected.inspect}") unless actual == expected
    end
  end

  def match_id(symbol, actual, where, path)
    if symbol.nil?
      return true if actual.nil?

      fail_at(where, "#{path} #{actual.inspect}, expected null")
      return false
    end
    return key_id(symbol) == actual || fail_at(where, "#{path} #{actual.inspect}, expected #{symbol}") if symbol.start_with?("$key:")

    bind_symbol(symbol, actual, "#{where}, #{path}")
  end

  def bind_symbol(symbol, actual, where)
    if actual.nil?
      fail_at(where, "null, expected #{symbol}")
      return false
    end
    if @ids.key?(symbol)
      return true if @ids[symbol] == actual

      fail_at(where, "#{actual}, but #{symbol} is #{@ids[symbol]}")
      return false
    end
    if @symbols.key?(actual)
      fail_at(where, "#{actual} is #{@symbols[actual]} already, so it cannot be #{symbol}")
      return false
    end
    @ids[symbol] = actual
    @symbols[actual] = symbol
    true
  end

  def match_event(link, actual, where, path)
    expected = link && @events.fetch(Integer(EVENT.match(link)[1], 10)) { :unwritten }
    fail_at(where, "#{path} #{actual.inspect}, expected #{link.inspect}") if expected != actual
  end

  def match_time(link, actual, where, path)
    seconds = Integer(TIME.match(link)[1], 10)
    if @times.key?(seconds)
      fail_at(where, "#{path} #{actual.iso8601(6)} is not #{link} (#{@times[seconds].iso8601(6)})") if @times[seconds] != actual
      return
    end
    @times.each do |other, time|
      next if (seconds <=> other) == (actual <=> time)

      fail_at(where, "#{path} #{actual.iso8601(6)} for #{link} is out of order with @t:#{other} (#{time.iso8601(6)})")
    end
    @times[seconds] = actual
  end

  def label(command, index) = "#{name} command #{index + 1} (#{command.fetch("command")}, #{command.fetch("at")})"

  def fail_at(where, message)
    @failures << "#{where}: #{message}"
    false
  end
end
