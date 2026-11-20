module Leverage
  module Transitions
    # Scripted outcomes per command, with no database (milestone 2 plan
    # §2.1): what a controller test answers instead of the pipeline, so it
    # needs no entry (WP6, WP8, WP9). Transitions.with_stand_in puts it in
    # place for a block; outside one the real pipeline always runs.
    #
    #   stand_in = Leverage::Transitions::StandIn.new
    #   stand_in.script("claim", Outcome.refused(Refusal.new(code: "not_eligible")))
    #   stand_in.script("submit") { |request| Outcome.completed({ "review_id" => id }) }
    #   Leverage::Transitions.with_stand_in(stand_in) { post ... }
    #   stand_in.requests   # every Request it was given, in order
    class StandIn
      # A command the test did not script.
      class NotScripted < StandardError; end

      attr_reader :requests

      def initialize
        @scripts = {}
        @requests = []
      end

      # An Outcome to answer every time, or a block that gets the Request
      # and returns one (or raises, as the pipeline would).
      def script(command, outcome = nil, &block)
        raise ArgumentError, "script an Outcome or a block" unless outcome.nil? ^ block.nil?

        @scripts[command.to_s] = block || ->(_request) { outcome }
        self
      end

      def apply(request)
        @requests << request
        script = @scripts.fetch(request.command) { raise NotScripted, "no outcome scripted for #{request.command}" }
        script.call(request)
      end
    end
  end
end
