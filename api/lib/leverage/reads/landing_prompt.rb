require "erb"

module Leverage
  module Reads
    # The one-line prompt that gives a seat its token and the join address.
    module LandingPrompt
      # A scheme, host name, IPv4 or bracketed IPv6 address, and optional port.
      ADDRESS = %r{\Ahttps?://(?:[A-Za-z0-9.-]+|\[[0-9A-Fa-f:]+\])(?::\d{1,5})?\z}

      def self.call(address:, token:, connection:)
        path = Contract.registry.fetch("operations").find { |operation| operation.fetch("operation_id") == "get_join" }.fetch("path")
        join_url = "#{address}#{path}"
        join_url += "?connection=mcp" if connection == "mcp"

        template = Rails.root.join("config/landing_prompt.txt.erb").read
        ERB.new(template).result_with_hash(address: address, token: token, join_url: join_url).strip
      end
    end
  end
end
