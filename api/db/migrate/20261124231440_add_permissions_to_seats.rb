# App round 2, contract decision UX-10: every seat has three permissions,
# Work on tasks, Deliver tasks and Create tasks, each on unless the owner
# turns it off. Every seat that exists gets all three on. A seat that
# connects on its own now reports its own model and effort (UX-9), so the
# values the owner typed for it at Connect are cleared, to read "Not
# reported yet" until it reports (UX-7). Seats are outside the replay, so no
# event carries any of this.
class AddPermissionsToSeats < ActiveRecord::Migration[8.1]
  def up
    add_column :seats, :may_work, :boolean, null: false, default: true
    add_column :seats, :may_deliver, :boolean, null: false, default: true
    add_column :seats, :may_create, :boolean, null: false, default: true
    execute "UPDATE seats SET model = '', effort = '' WHERE credential_id IS NULL"
  end

  # The permissions go; the cleared model and effort are not restored.
  def down
    remove_column :seats, :may_create
    remove_column :seats, :may_deliver
    remove_column :seats, :may_work
  end
end
