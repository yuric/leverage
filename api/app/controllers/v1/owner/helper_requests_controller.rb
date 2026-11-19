module V1
  module Owner
    # GET /v1/owner/helper-requests/{id} (get_helper_request): one helper
    # request with each check's progress (IN-23, MA-20). With wait it holds
    # the call until the request changed after changed_after, or wait runs
    # out; the wait gives its database connection back between looks.
    class HelperRequestsController < ApplicationController
      include AuthenticatesOwner

      def show
        status = Leverage::Reads::HelperRequest.call(current_caller.workspace_id, uuid_param!(:id), wait: wait,
          changed_after: changed_after)
        raise NotFound, "No such helper request" unless status

        render json: status
      end

      private

      # Seconds to wait, 0 to 30 (default 0); anything else is 400 malformed.
      def wait
        return 0 unless params.key?(:wait)

        value = Integer(params[:wait].to_s, 10, exception: false)
        raise Malformed, "wait must be a whole number from 0 to 30" unless value && (0..30).cover?(value)

        value
      end

      # The updated_at the caller last saw, or nil.
      def changed_after
        return nil unless params.key?(:changed_after)

        Time.iso8601(params[:changed_after].to_s)
      rescue ArgumentError
        raise Malformed, "changed_after must be a date and time"
      end
    end
  end
end
