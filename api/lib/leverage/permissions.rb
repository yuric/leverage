module Leverage
  # A seat's permissions (contract decisions UX-10, UX-11a): Work on tasks,
  # Deliver tasks and Create tasks, stored as seats.may_work, may_deliver and
  # may_create and on unless the owner turns one off.
  #
  # The rule of thumb every claim and lease path follows: what counts or
  # leases a seat as a task's builder reads builds?; what counts or gives a
  # seat a review or a job reads works?; a lease for approved outward actions
  # reads neither, so turning a permission off never strands an approved
  # action. Work off stops new work only; held work goes on.
  module Permissions
    # The interface's names (registry list seat_permissions) and their columns.
    COLUMNS = { "work" => :may_work, "deliver" => :may_deliver, "create" => :may_create }.freeze

    module_function

    # May claim tasks, reviews and jobs its role allows.
    def works?(seat) = seat.may_work

    # May be counted, offered and leased as a task's builder: it works and
    # may hand the task in.
    def builds?(seat) = seat.may_work && seat.may_deliver

    # May add a task with create_task.
    def creates?(seat) = seat.may_create

    # The seat's set as SeatPermissions writes it, in the registry's order.
    def to_h(seat)
      Contract.list("seat_permissions").to_h { |name| [ name, seat.public_send(COLUMNS.fetch(name)) ] }
    end

    # The column values for a SeatPermissions object (the whole set).
    def columns(set)
      Contract.list("seat_permissions").to_h { |name| [ COLUMNS.fetch(name), set.fetch(name) ] }
    end
  end
end
