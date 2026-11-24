require "erb"

module Leverage
  module Reads
    # GET /v1/join (GA-12): render the seat's instructions without polling
    # for work. Authentication supplies the seat, never the bearer token.
    module JoinInstructions
      TEMPLATES = { "http" => "join_http.md.erb", "mcp" => "join_mcp.md.erb" }.freeze
      MCP_COMMAND = %r{\A/[A-Za-z0-9 ._/-]+/LeverageMCP\z}

      Call = Data.define(:id, :method, :path)

      Page = Data.define(:role, :seat_name, :address, :operations, :calls, :lease_seconds, :mcp_command) do
        def article = role == "orchestrator" ? "an" : "a"
        def builds? = Roles.acts_as?(role, "builder")
        def reviews? = Roles.acts_as?(role, "reviewer")
        def works_on_jobs? = Roles.acts_as?(role, "orchestrator") || Roles.acts_as?(role, "planner")
        def role_file? = Roles.role_file?(role)
        def job_rules = Roles.job_rules(role)
        def offline_after = RolePresence::OFFLINE_AFTER
        def heartbeat_interval = format("%g", lease_seconds.fdiv(3).floor(1))
        def get_binding = binding
      end

      module_function

      def call(seat:, address:, connection: nil)
        connection = "http" if connection.nil?
        template = TEMPLATES.fetch(connection) do
          raise Http::RequestSchema::Malformed, "connection must be http or mcp"
        end
        unless LandingPrompt::ADDRESS.match?(address)
          raise Http::RequestSchema::Malformed, "The address cannot be used in a command"
        end

        role = seat.role
        operations = Roles::DEFINITIONS.fetch(role).fetch("operations")
        seat_name = seat.name.gsub(LEVERAGE_TOKEN_IN_TEXT, "[FILTERED]") if connection == "http"
        page = Page.new(role: role, seat_name: seat_name, address: address, operations: operations,
          calls: (http_calls(operations) if connection == "http"), lease_seconds: lease_seconds(seat),
          mcp_command: (mcp_command if connection == "mcp"))
        source = Rails.root.join("config", template).read
        text = ERB.new(source, trim_mode: "-").result(page.get_binding)
        { role: role, connection: connection, text: "#{text.strip}\n" }
      end

      def http_calls(ids)
        registry = Contract.registry.fetch("operations").index_by { |operation| operation.fetch("operation_id") }
        ids.select { |id| Http::RouteTable.serves?(id) }.map do |id|
          operation = registry.fetch(id)
          Call.new(id: id, method: operation.fetch("method"), path: operation.fetch("path"))
        end
      end

      def lease_seconds(seat)
        return unless Roles.acts_as?(seat.role, "builder") || Roles.acts_as?(seat.role, "reviewer")

        Workspace.where(id: seat.workspace_id).pick(:lease_length_seconds)
      end

      def mcp_command
        command = ENV["LEVERAGE_MCP_COMMAND"]
        command if MCP_COMMAND.match?(command) && !LEVERAGE_TOKEN_IN_TEXT.match?(command)
      end
    end
  end
end
