module V1
  module Helper
    # GET /v1/helper/next?wait=30 (get_helper_next): the helper's oldest
    # queued request, marked picked up, waiting up to `wait` seconds for one
    # (IF-15, IF-14). It waits like GET /v1/next (V1::Agent::NextController):
    # outside any transaction, a connection only while it looks, a 401 at
    # the look after the helper's token was replaced, and one waiting poll
    # at a time: a second one ends the first, which answers null.
    class NextController < ApplicationController
      include AuthenticatesHelper

      MAX_WAIT = 30

      def show
        wait = wait_seconds
        Leverage::Transitions::RecordPoll.helper(current_helper)
        picked = Leverage::LongPoll.wait(wait, key: "helper:#{current_helper.id}") { look }
        render json: { request: picked && Leverage::Reads::HelperNext.body(picked) }
      end

      private

      def wait_seconds
        raw = params[:wait]
        return MAX_WAIT if raw.nil?
        raise Malformed, "wait is a whole number of seconds from 0 to #{MAX_WAIT}" unless raw.is_a?(String) && /\A\d{1,2}\z/.match?(raw) && raw.to_i <= MAX_WAIT

        raw.to_i
      end

      # One look: the oldest queued request, picked up, or nil.
      def look
        ActiveRecord::Base.uncached do
          helper = ::Helper.find_by(id: current_helper.id)
          raise Unauthenticated unless helper && helper.token_hash == current_helper.token_hash

          found = Leverage::Reads::HelperNext.call(helper.workspace_id)
          found && Leverage::Transitions::MarkRead.helper_request(found)
        end
      end
    end
  end
end
