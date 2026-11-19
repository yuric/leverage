#!/usr/bin/env ruby
# The speed run's driver (milestone 2 plan EN-19, 5.3): fifty seats that
# connect on their own, half builders and half reviewers, work through
# tasks that were put in Ready beforehand, over HTTP, for 120 seconds,
# heartbeating every 2 seconds. scripts/speed_run.sh runs it in a
# container of the compose network (the API is http://api:3000 there);
# scripts/speed_report.py then reads the API's command lines.
#
# It loads nothing of the application: only Ruby's standard library. The
# method and path of every call come from api/contract/registry.json, never
# typed here. Everything it signs in with is made up for this run and lives
# only in this process.
#
#   ruby script/speed/run.rb [--url URL] [--seats 50] [--seconds 120]
#                            [--tick 2] [--smoke]
#
# --smoke is 4 seats for 20 seconds. Exit codes: 0 the run worked; 1 the
# server could not be set up or a call was refused or failed that should
# not have been; 2 no seat did any work.
require "json"
require "net/http"
require "optparse"
require "securerandom"
require "uri"

module Speed
  REGISTRY = File.expand_path("../../contract/registry.json", __dir__)

  Options = Struct.new(:url, :seats, :seconds, :tick, keyword_init: true)

  # Operation id -> [method, path template], from the contract.
  OPERATIONS = JSON.parse(File.read(REGISTRY)).fetch("operations")
    .to_h { |op| [ op.fetch("operation_id"), [ op.fetch("method"), op.fetch("path") ] ] }.freeze

  # What the run saw, shared by every thread.
  class Tally
    def initialize
      @mutex = Mutex.new
      @statuses = Hash.new(0)
      @unexpected = []
      @events = Hash.new(0)
    end

    def request(operation_id, status, ok)
      @mutex.synchronize do
        @statuses["#{operation_id} #{status}"] += 1
        @unexpected << "#{operation_id} answered #{status}" if !ok && @unexpected.size < 25
      end
    end

    def note(name) = @mutex.synchronize { @events[name] += 1 }
    def count(name) = @mutex.synchronize { @events[name] }
    def failures = @mutex.synchronize { @unexpected.dup }
    def statuses = @mutex.synchronize { @statuses.sort.to_h }
    def events = @mutex.synchronize { @events.sort.to_h }
  end

  # One keep-alive connection, used by one thread.
  class Client
    attr_reader :token

    def initialize(base, tally, token: nil)
      @uri = URI(base)
      @tally = tally
      @token = token
      @http = nil
    end

    def token=(value)
      @token = value
    end

    # Sends the operation. Returns [status, parsed body]. expect lists the
    # statuses this call may answer; anything else is counted as unexpected.
    def call(operation_id, ids: {}, body: nil, query: nil, expect: [ 200 ])
      method, template = OPERATIONS.fetch(operation_id)
      path = template.gsub(/\{([a-z_]+)\}/) { ids.fetch(Regexp.last_match(1)) }
      path += "?#{URI.encode_www_form(query)}" if query
      request = (method == "GET" ? Net::HTTP::Get : Net::HTTP::Post).new(path)
      request["Authorization"] = "Bearer #{@token}" if @token
      request["Idempotency-Key"] = "speed-#{SecureRandom.hex(10)}" if method == "POST"
      if body
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(body)
      end
      response = send_request(request)
      parsed = begin
        JSON.parse(response.body.to_s)
      rescue JSON::ParserError
        {}
      end
      status = response.code.to_i
      @tally.request(operation_id, status, expect.include?(status))
      [ status, parsed ]
    end

    private

    def send_request(request)
      attempts = 0
      begin
        @http ||= Net::HTTP.start(@uri.host, @uri.port, read_timeout: 60, open_timeout: 10, keep_alive_timeout: 30)
        @http.request(request)
      rescue EOFError, Errno::ECONNRESET, Errno::EPIPE, Net::OpenTimeout, IOError
        @http = nil
        attempts += 1
        retry if attempts < 2
        raise
      end
    end
  end

  # What every seat does: one tick every `tick` seconds.
  class Seat
    def initialize(client, tally, role:, tick:, deadline:)
      @client = client
      @tally = tally
      @role = role
      @tick = tick
      @deadline = deadline
      @held = nil
      @steps = []
    end

    def run(start_at)
      sleep([ start_at - monotonic, 0 ].max)
      next_tick = monotonic
      while monotonic < @deadline
        tick
        next_tick += @tick
        pause = next_tick - monotonic
        sleep(pause) if pause.positive?
      end
    rescue StandardError => e
      @tally.request("seat_thread", 0, false)
      @tally.note("seat thread stopped: #{e.class}")
    end

    private

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def tick
      return look_for_work unless @held

      heartbeat
      step if @held
    end

    # The way an agent asks: what is next, and only then claim it.
    def look_for_work
      status, body = @client.call("get_next", query: { "wait" => 0 })
      return unless status == 200 && body["kind"] == (@role == :builder ? "task" : "review")

      @role == :builder ? claim_task : claim_review
    end

    def claim_task
      status, body = @client.call("claim_next_task", expect: [ 200, 409 ])
      return refused unless status == 200

      result = body.fetch("result")
      id = result.dig("task", "id")
      criteria = result.dig("briefing", "contract", "criteria").select { |c| c["kind"] == "build" }
      @held = { operation: "heartbeat_task", ids: { "id" => id } }
      @steps = [ [ "acknowledge_task_briefing", { "id" => id }, { "briefing_hash" => result.dig("briefing", "hash") } ] ]
      criteria.each do |criterion|
        ids = { "id" => id, "cid" => criterion.fetch("id") }
        @steps << [ "start_criterion", ids, nil ]
        @steps << [ "pass_criterion", ids, { "evidence" => { "kind" => "link", "value" => "https://example.test/speed/#{criterion.fetch("id")}" } } ]
      end
      @steps << [ "submit_task", { "id" => id }, { "handoff_note" => "Done.", "work_reference" => "speed-run" } ]
      @tally.note("tasks claimed")
    end

    def claim_review
      status, body = @client.call("claim_next_review", expect: [ 200, 409 ])
      return refused unless status == 200

      result = body.fetch("result")
      id = result.dig("review", "id")
      @held = { operation: "heartbeat_review", ids: { "id" => id } }
      @steps = [
        [ "acknowledge_review_briefing", { "id" => id }, { "briefing_hash" => result.dig("briefing", "hash") } ],
        [ "give_verdict", { "id" => id },
          { "verdict" => "passed", "failed_criteria" => [], "notes" => "Every criterion holds.", "tokens" => 0, "spend" => 0 } ]
      ]
      @tally.note("reviews claimed")
    end

    def refused
      @tally.note("claims refused")
    end

    def heartbeat
      status, = @client.call(@held.fetch(:operation), ids: @held.fetch(:ids))
      drop unless status == 200
      @tally.note("heartbeats") if status == 200
    end

    def step
      operation, ids, body = @steps.shift
      status, = @client.call(operation, ids: ids, body: body)
      return drop unless status == 200

      @tally.note(operation)
      drop if @steps.empty?
    end

    def drop
      @held = nil
      @steps = []
    end
  end

  # Sets the server up, connects the seats and preloads the tasks.
  class Setup
    attr_reader :owner, :seats, :preloaded

    def initialize(options, tally)
      @options = options
      @tally = tally
      @owner = Client.new(options.url, tally)
      @seats = []
    end

    def run
      wait_for_server
      sign_in
      connect_seats
      preload_tasks
    end

    private

    def wait_for_server
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 90
      loop do
        begin
          status, = @owner.call("get_health", expect: [ 200, 503 ])
          return if status == 200
        rescue SystemCallError, IOError, Net::OpenTimeout
          nil
        end
        abort "speed_run: the API did not answer /v1/health in 90 seconds" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 1
      end
    end

    def sign_in
      email = "speed-#{SecureRandom.hex(4)}@example.test"
      password = SecureRandom.hex(16)
      status, body = @owner.call("get_setup_state")
      abort "speed_run: get_setup_state answered #{status}" unless status == 200
      if body["owner_exists"] || body["setup_complete"]
        abort "speed_run: the server already has an owner; start from an empty database"
      end
      status, body = @owner.call("create_owner", body: { "email_address" => email, "password" => password })
      abort "speed_run: create_owner answered #{status}: #{body.to_json[0, 300]}" unless status == 200
      @owner.token = body.dig("result", "session_token") or abort "speed_run: create_owner gave no session"
    end

    def connect_seats
      @options.seats.times do |index|
        role = index.even? ? "builder" : "reviewer"
        status, body = @owner.call("connect_seat",
          body: { "name" => "Speed #{role} #{index / 2 + 1}", "role" => role, "provider" => (role == "builder" ? "claude" : "codex"),
                  "model" => nil, "effort" => nil, "strength_rank" => nil, "credential_id" => nil })
        abort "speed_run: connect_seat answered #{status}: #{body.to_json[0, 300]}" unless status == 200
        @seats << [ role.to_sym, body.dig("result", "seat_token") || abort("speed_run: connect_seat showed no token") ]
      end
    end

    # Enough Ready tasks that no builder runs out: a task takes a builder
    # seven ticks (claim, acknowledge, two criteria, submit).
    def preload_tasks
      builders = @options.seats / 2
      count = builders * ((@options.seconds / (7.0 * @options.tick)).ceil + 2)
      queue = Queue.new
      count.times { |n| queue << n }
      workers = Array.new([ 8, count ].min) do
        Thread.new do
          client = Client.new(@options.url, @tally, token: @owner.token)
          loop do
            n = begin
              queue.pop(true)
            rescue ThreadError
              break
            end
            add_ready_task(client, n)
          end
        end
      end
      workers.each(&:join)
      @preloaded = count
    end

    def add_ready_task(client, n)
      title = "Speed task #{n + 1}"
      status, body = client.call("add_task", body: { "title" => title, "goal" => "Measure the speed.",
                                                      "priority" => "normal", "work_reference" => "speed-run", "state" => "backlog" })
      return unless status == 200

      id = body.dig("result", "task", "id") || body.dig("result", "task_id") || body.dig("result", "id")
      client.call("complete_contract", ids: { "id" => id },
        body: { "title" => title, "goal" => "Measure the speed.", "details" => nil,
                "criteria" => [ { "text" => "The first part holds.", "kind" => "build" },
                                { "text" => "The second part holds.", "kind" => "build" },
                                { "text" => "An independent reviewer agrees.", "kind" => "review" } ],
                "actions" => [], "minimum_strength_rank" => nil, "budget_cap" => nil, "work_reference" => "speed-run" })
    end
  end

  # When each seat's first tick is, in the order the seats were connected.
  def self.seat_starts(start_at, seats:, tick:)
    Array.new(seats, start_at)
  end

  def self.main(argv)
    options = Options.new(url: ENV.fetch("SPEED_API_URL", "http://api:3000"), seats: 50, seconds: 120, tick: 2.0)
    OptionParser.new do |o|
      o.on("--url URL") { |v| options.url = v }
      o.on("--seats N", Integer) { |v| options.seats = v }
      o.on("--seconds N", Integer) { |v| options.seconds = v }
      o.on("--tick N", Float) { |v| options.tick = v }
      o.on("--smoke") { options.seats = 4; options.seconds = 20 }
    end.parse!(argv)
    abort "speed_run: --seats must be an even number of at least 2" unless options.seats >= 2 && options.seats.even?

    tally = Tally.new
    setup = Setup.new(options, tally)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    setup.run
    puts "speed_run: set up in #{(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(1)} seconds: " \
         "#{options.seats} seats, #{setup.preloaded} tasks put in Ready"
    $stdout.flush

    start_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
    deadline = start_at + options.seconds
    starts = seat_starts(start_at, seats: setup.seats.size, tick: options.tick)
    threads = setup.seats.each_with_index.map do |(role, token), index|
      client = Client.new(options.url, tally, token: token)
      Thread.new { Seat.new(client, tally, role: role, tick: options.tick, deadline: deadline).run(starts[index]) }
    end
    threads.each(&:join)

    report(options, tally)
  end

  def self.report(options, tally)
    puts "speed_run: #{options.seats} seats, #{options.seconds} seconds, one tick every #{options.tick} seconds"
    tally.events.each { |name, count| puts "speed_run: #{name}: #{count}" }
    tally.statuses.each { |name, count| puts "speed_run: #{name}: #{count}" }
    failures = tally.failures
    failures.each { |text| warn "speed_run: UNEXPECTED #{text}" }
    work = tally.count("heartbeats") + tally.count("tasks claimed") + tally.count("reviews claimed")
    exit 2 if work.zero?
    exit 1 unless failures.empty?
  end
end

Speed.main(ARGV) if $PROGRAM_NAME == __FILE__
