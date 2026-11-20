module V1
  module Owner
    # GET /v1/owner/events (list_events): the stable events tail (IF-18,
    # MA-20). after_seq, limit and wait are checked here; a value outside the
    # contract's range is 400 malformed.
    class EventsController < ApplicationController
      include AuthenticatesOwner

      def index
        render json: Leverage::Reads::EventsTail.call(current_caller.workspace_id, after_seq: integer(:after_seq, 0, 0..),
          limit: integer(:limit, 100, 1..500), wait: integer(:wait, 0, 0..30))
      end

      private

      # A whole number inside the range, or the default when the query has none.
      def integer(name, default, range)
        return default unless params.key?(name)

        value = Integer(params[name].to_s, 10, exception: false)
        raise Malformed, "#{name} must be a whole number from #{range.begin} to #{range.end || "any size"}" unless value && range.cover?(value)

        value
      end
    end
  end
end
