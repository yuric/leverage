module Leverage
  module Reads
    # The roster (list_seats; milestone 2 plan MA-20): every seat that is not
    # removed, in the order they were connected. Whether a seat is running
    # and when it last polled are not events, so the app reads this again
    # every 10 seconds as well as after an event.
    module Seats
      module_function

      # Raises ActiveRecord::RecordNotFound for an unknown workspace.
      def call(workspace_id)
        Snapshot.call(workspace_id) do |as_of_seq|
          seats = Seat.where(workspace_id: workspace_id, removed_at: nil).order(:created_at, :id)
          { seats: seats.map { |seat| Shapes.seat(seat) }, as_of_seq: as_of_seq }
        end
      end
    end
  end
end
