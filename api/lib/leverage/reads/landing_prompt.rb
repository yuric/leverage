require "erb"

module Leverage
  module Reads
    # The landing prompt of a seat that connects on its own (get_landing_prompt;
    # PRD Clients). The HTTP form describes the calls this server serves.
    # The MCP form names the role's tools from the contract. Each form has
    # its own template, and only the HTTP form uses the request address.
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
      TEMPLATES = { "http" => "landing_prompt.md.erb", "mcp" => "landing_prompt_mcp.md.erb" }.freeze

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

      # { text:, check_interval_minutes:, connection: }, or nil when the
      # workspace has no such seat or it was removed. Raises AppRunSeat for
      # a seat the app runs, UnusableAddress for an unsafe HTTP base_url and
      # ActiveRecord::RecordNotFound for an unknown workspace.
      def call(workspace_id, seat_id, base_url:, connection: "http")
        template = TEMPLATES.fetch(connection)
        http = connection == "http"
        Snapshot.call(workspace_id) do |_as_of_seq|
          seat = Seat.find_by(workspace_id: workspace_id, id: seat_id, removed_at: nil)
          next nil unless seat
          raise AppRunSeat, "The app runs this seat" if seat.credential_id

          if http && !ADDRESS.match?(base_url)
            raise UnusableAddress, "The address cannot be used in a command"
          end

          lease_seconds = Workspace.where(id: workspace_id).pick(:lease_length_seconds)
          page = page(seat, base_url, lease_seconds, http: http)
          { text: render(page, template), check_interval_minutes: page.check_interval_minutes, connection: connection }
        end
      end

      def page(seat, base_url, lease_seconds, http:)
        Page.new(seat_name: (seat.name if http), role: seat.role, base_url: (base_url if http),
          calls: calls_for(seat.role, served_only: http),
          lease: duration(lease_seconds),
          check_interval_minutes: JOB_ROLES.include?(seat.role) ? JOB_CHECK_INTERVAL_MINUTES : CHECK_INTERVAL_MINUTES)
      end

      # The calls in contract order. The HTTP form only lists served routes.
      def calls_for(role, served_only:)
        entry = Contract.roles.fetch("roles").find { |candidate| candidate.fetch("role") == role }
        operations = Contract.registry.fetch("operations").to_h { |operation| [ operation.fetch("operation_id"), operation ] }
        ids = entry.fetch("operations")
        ids = ids.select { |id| Http::RouteTable.serves?(id) } if served_only
        ids.map do |id|
          operation = operations.fetch(id)
          Call.new(id: id, method: operation.fetch("method"), path: operation.fetch("path"))
        end
      end

      def duration(seconds)
        return "#{seconds} seconds" unless (seconds % 60).zero?

        minutes = seconds / 60
        minutes == 1 ? "1 minute" : "#{minutes} minutes"
      end

      def render(page, template)
        source = Rails.root.join("config", template).read
        "#{ERB.new(source, trim_mode: "-").result(page.get_binding).strip}\n"
      end
    end
  end
end
