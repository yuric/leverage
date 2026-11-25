require "test_helper"
require_relative "rows"

# The migration that gives every seat its permissions (contract decision
# UX-10): three switches, on for every seat that exists, and the model and
# effort the owner typed for a seat that connects on its own cleared, since
# such a seat now reports its own (UX-7, UX-9). Seats are inserted while the
# migration is undone, so the test proves what the migration does to
# existing rows, not only the column default.
class SeatPermissionsTest < ActiveSupport::TestCase
  include DbRows

  MIGRATION = Dir[File.expand_path("../../db/migrate/*_add_permissions_to_seats.rb", __dir__)].first
  COLUMNS = %w[may_work may_deliver may_create].freeze

  def migration
    assert MIGRATION, "no *_add_permissions_to_seats.rb migration"
    require MIGRATION
    AddPermissionsToSeats.new.tap { |instance| instance.verbose = false }
  end

  def columns
    sql("SELECT column_name FROM information_schema.columns WHERE table_name = 'seats'").rows.flatten
  end

  def row(id)
    sql("SELECT may_work, may_deliver, may_create, model, effort FROM seats WHERE id = $1", id).to_a.first
  end

  teardown do
    db.schema_cache.clear!
    ActiveRecord::Base.descendants.each(&:reset_column_information)
  end

  test "UX-10: every seat has the three permissions, on by default" do
    COLUMNS.each { |column| assert_includes columns, column }
    id = seat
    assert_equal [ true, true, true ], row(id).values_at(*COLUMNS)
  end

  test "UX-10: existing seats get all three on; a Prompt seat's typed model and effort are cleared" do
    change = migration
    change.migrate(:down)
    COLUMNS.each { |column| refute_includes columns, column, "down drops #{column}" }
    native = seat(credential_id: credential, model: "made-up-native-model", effort: "high")
    prompt = seat(credential_id: nil, model: "made-up-typed-model", effort: "medium")
    change.migrate(:up)
    [ native, prompt ].each { |id| assert_equal [ true, true, true ], row(id).values_at(*COLUMNS) }
    assert_equal [ "made-up-native-model", "high" ], row(native).values_at("model", "effort")
    assert_equal [ "", "" ], row(prompt).values_at("model", "effort")
  end

  test "UX-10: the permissions are never null" do
    id = seat
    assert_raises(ActiveRecord::NotNullViolation) do
      sql("UPDATE seats SET may_create = NULL WHERE id = $1", id)
    end
  end
end
