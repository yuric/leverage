require "erb"

module Leverage
  module Reads
    # The landing prompt of a seat that connects on its own (get_landing_prompt;
    # PRD Clients, milestone 2 plan MA-12, SC-10, Q-15, the owner's issue 11):
    # the text the owner pastes into the agent. It is filled from one
    # template, config/landing_prompt.md.erb, with the seat's role and name,
    # the address the request came in on, the calls the role may make and
    # this server serves, and the workspace's lease length. It never holds a
    # token: the seat's token is shown once, by connect_seat, and the prompt
    # tells the agent to read it from an environment variable the template
    # names.
    #
    # The calls come from roles.json (what the role may make) and the
    # registry (method and path), kept to the operations Http::RouteTable
    # serves: a call the role may make that is not served yet answers 404, so
    # it is left out. Each is listed by name, method and path only: the
    # owner reads this text in the Connect sheet, and the contract's
    # one-line summaries use engine words the owner's screens do not (PRD
    # L794); the briefing tells the agent what each call is for.
    module LandingPrompt
      CHECK_INTERVAL_MINUTES = 20
      # An orchestrator or a planner checks for work every minute, also
      # while it works on a job (milestone 4 review, finding 19): an
      # orchestrator is offline 90 seconds after its last poll (PRD L401;
      # Leverage::RolePresence::OFFLINE_AFTER), and its jobs wait while it
      # is; a planner's presence is not read, and a draft it does not claim
      # or finish within the check timeouts is queued once more, then
      # dropped (JobTimer.draft_miss; the second review of finding 19).
      JOB_CHECK_INTERVAL_MINUTES = 1
      JOB_ROLES = %w[orchestrator planner].freeze
      TEMPLATE = "landing_prompt.md.erb".freeze

      # The seat is one the app runs, which needs no prompt (409 invalid_state).
      class AppRunSeat < StandardError; end

      # The address the request came in on cannot be put in a command safely.
      class UnusableAddress < StandardError; end

      # An address that is safe to put in a pasted command: a scheme, a host
      # name, an IPv4 or bracketed IPv6 address, and an optional port.
      ADDRESS = %r{\Ahttps?://(?:[A-Za-z0-9.-]+|\[[0-9A-Fa-f:]+\])(?::\d{1,5})?\z}

      # One call of the seat's role, as the template lists it.
      Call = Data.define(:id, :method, :path)

      # What the template reads: the page's locals and nothing else.
      Page = Data.define(:seat_name, :role, :base_url, :calls, :lease, :check_interval_minutes) do
        def briefing_call = calls.find { |call| call.id.start_with?("get_") && call.id.end_with?("_briefing") }
        def acknowledge_call = calls.find { |call| call.id.start_with?("acknowledge_") }
        def heartbeat_call = calls.find { |call| call.id.start_with?("heartbeat_") }
        def release_call = calls.find { |call| call.id.start_with?("release_") }
        def claim_call = calls.find { |call| call.id.start_with?("claim_next_") }
        def command_call = calls.find { |call| call.id == "get_command" }
        def submit_job_call = calls.find { |call| call.id == "submit_job_result" }
        # An orchestrator or a planner: it claims jobs, and has no briefing,
        # no lease and no release.
        def job_role? = JOB_ROLES.include?(role)
        # What the role holds one of at a time.
        def unit = job_role? ? "job" : (role == "reviewer" ? "review" : "task")
        def article = role.match?(/\A[aeiou]/) ? "an" : "a"
        # How often it checks for work, in words.
        def check_interval = job_role? ? "60 seconds" : "#{check_interval_minutes} minutes"
        def get_binding = binding
      end

      module_function

      # { text:, check_interval_minutes: }, or nil when the workspace has no
      # such seat or it was removed. Raises AppRunSeat for a seat the app runs
      # and UnusableAddress for a base_url that is not safe to paste. Raises
      # ActiveRecord::RecordNotFound for an unknown workspace.
      def call(workspace_id, seat_id, base_url:)
        Snapshot.call(workspace_id) do |_as_of_seq|
          seat = Seat.find_by(workspace_id: workspace_id, id: seat_id, removed_at: nil)
          next nil unless seat
          raise AppRunSeat, "The app runs this seat" if seat.credential_id

          raise UnusableAddress, "The address cannot be used in a command" unless ADDRESS.match?(base_url)

          lease_seconds = Workspace.where(id: workspace_id).pick(:lease_length_seconds)
          page = page(seat, base_url, lease_seconds)
          { text: render(page), check_interval_minutes: page.check_interval_minutes }
        end
      end

      def page(seat, base_url, lease_seconds)
        Page.new(seat_name: seat.name, role: seat.role, base_url: base_url, calls: calls_for(seat.role),
          lease: duration(lease_seconds),
          check_interval_minutes: JOB_ROLES.include?(seat.role) ? JOB_CHECK_INTERVAL_MINUTES : CHECK_INTERVAL_MINUTES)
      end

      # The calls the role may make that the server serves, in the order
      # roles.json lists them.
      def calls_for(role)
        entry = Contract.roles.fetch("roles").find { |candidate| candidate.fetch("role") == role }
        operations = Contract.registry.fetch("operations").to_h { |operation| [ operation.fetch("operation_id"), operation ] }
        entry.fetch("operations").select { |id| Http::RouteTable.serves?(id) }.map do |id|
          operation = operations.fetch(id)
          Call.new(id: id, method: operation.fetch("method"), path: operation.fetch("path"))
        end
      end

      def duration(seconds)
        return "#{seconds} seconds" unless (seconds % 60).zero?

        minutes = seconds / 60
        minutes == 1 ? "1 minute" : "#{minutes} minutes"
      end

      def render(page)
        source = Rails.root.join("config", TEMPLATE).read
        "#{ERB.new(source, trim_mode: "-").result(page.get_binding).strip}\n"
      end
    end
  end
end
