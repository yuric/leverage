module Leverage
  module Reads
    # What GET /v1/helper/next answers (milestone 2 plan WP8, IF-15): the
    # oldest request of the helper's workspace that is still queued, as the
    # contract's HelperRequest. The caller marks it picked up
    # (Transitions::MarkRead.helper_request); this read only selects.
    module HelperNext
      module_function

      # The oldest queued HelperRequest of the workspace, or nil.
      def call(workspace_id)
        ::HelperRequest.where(workspace_id: workspace_id, state: "queued").order(:requested_at, :id).take
      end

      # The request as the contract's HelperRequest, times in UTC with six
      # fractional digits (the app gives updated_at back as changed_after).
      def body(request)
        { "id" => request.id, "kind" => request.kind, "seat_id" => request.seat_id, "credential_id" => request.credential_id,
          "state" => request.state, "requested_at" => time(request.requested_at), "picked_up_at" => time(request.picked_up_at),
          "finished_at" => time(request.finished_at), "result" => request.result, "params" => request.params,
          "progress" => request.progress, "updated_at" => time(request.updated_at) }
      end

      def time(value) = value&.utc&.iso8601(6)
    end
  end
end
