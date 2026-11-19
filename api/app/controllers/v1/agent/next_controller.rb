module V1
  module Agent
    # GET /v1/next?wait=30 (get_next): the first true item of the precedence
    # table, waiting up to `wait` seconds for one (PRD L514-L529, IF-14).
    # The wait happens outside any transaction and gives the connection back
    # between looks (LongPoll); each look reads the committed rows and sees
    # a seat that was removed or whose token was replaced meanwhile as 401.
    class NextController < ApplicationController
      include AuthenticatesSeat

      MAX_WAIT = 30

      def show
        wait = wait_seconds
        Leverage::Transitions::RecordPoll.seat(current_seat)
        item = Leverage::LongPoll.wait(wait) { look }
        render json: item || Leverage::Reads::NextItem::NONE
      end

      private

      # Whole seconds from 0 to 30; 30 when absent (IF-14).
      def wait_seconds
        raw = params[:wait]
        return MAX_WAIT if raw.nil?
        raise Malformed, "wait is a whole number of seconds from 0 to #{MAX_WAIT}" unless raw.is_a?(String) && /\A\d{1,2}\z/.match?(raw) && raw.to_i <= MAX_WAIT

        raw.to_i
      end

      # One look: the item, or nil when it is none. The query cache is off,
      # or the second look would repeat the first one's answers.
      def look
        ActiveRecord::Base.uncached do
          seat = Seat.find_by(id: current_seat.id, removed_at: nil)
          raise Unauthenticated unless seat && seat.token_hash == current_seat.token_hash

          item = Leverage::Reads::NextItem.call(seat)
          item unless item.fetch("kind") == "none"
        end
      end
    end
  end
end
