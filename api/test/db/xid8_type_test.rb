require "test_helper"

# events.xact_id is an xid8 (the deferred state trigger reads it, C7), a
# type Active Record does not know. Reading the table's columns must not
# warn "unknown OID" on every process's first look (milestone 1's log
# noise, reported by WP1): config/initializers/xid8_type.rb registers it as
# a string. The column stays out of Event (ignored_columns).
class Xid8TypeTest < ActiveSupport::TestCase
  test "reading the events table's columns warns of no unknown type" do
    _out, err = capture_io { ActiveRecord::Base.lease_connection.columns("events") }
    assert_no_match(/unknown OID/, err)
  end
end
