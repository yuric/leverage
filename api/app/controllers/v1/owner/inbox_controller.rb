module V1
  module Owner
    # GET /v1/owner/inbox (list_inbox; milestone 3 plan HE-37, HE-40): the
    # open Needs you items, each with the seq of its inbox.opened. after_seq
    # and wait are checked here; a value outside the contract's range is 400
    # malformed.
    class InboxController < ApplicationController
      include AuthenticatesOwner

      def index
        render json: Leverage::Reads::Inbox.call(current_caller.workspace_id, after_seq: integer(:after_seq, 0, 0..),
          wait: integer(:wait, 0, 0..30))
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
