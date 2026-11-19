require_relative "contract_helper"
require "time"

# Leverage::Contract::TraceBinder turns a golden trace's symbols into
# deterministic UUIDs and its relative times into instants.
class TraceBinderTest < Minitest::Test
  include ContractTestHelpers

  START = Time.utc(2026, 11, 19, 9, 0, 0)
  UUID = /\A\h{8}-\h{4}-5\h{3}-[89ab]\h{3}-\h{12}\z/

  def binder
    Leverage::Contract::TraceBinder.new(start: START)
  end

  def test_uuid_v5_matches_the_published_vector
    # RFC 9562's DNS namespace and the name "python.org", as Python's
    # uuid.uuid5 computes it.
    dns = "6ba7b810-9dad-11d1-80b4-00c04fd430c8"
    assert_equal "886313e1-3b8a-5372-9b90-0c9aee199e5d",
      Leverage::Contract::TraceBinder.uuid_v5(dns, "python.org")
  end

  def test_the_same_symbol_binds_to_the_same_uuid_in_two_runs
    first = binder.id("$task:1")
    assert_match UUID, first
    assert_equal first, Leverage::Contract::TraceBinder.new(start: START + 3600).id("$task:1")
  end

  def test_two_symbols_never_collide
    symbols = %w[$task:1 $task:2 $seat:builder $seat:reviewer $credential:claude_main $key:claim $key:claim_2 $rule:acceptance_criteria]
    ids = symbols.map { |symbol| binder.id(symbol) }
    assert_equal ids.uniq, ids
    refute_equal binder.id("$task:1"), binder.event_id(1)
  end

  def test_an_event_link_resolves_to_the_nth_expected_events_id
    assert_equal binder.event_id(7), binder.bind("@event:7")
    refute_equal binder.event_id(7), binder.event_id(8)
    assert_match UUID, binder.event_id(1)
  end

  def test_relative_times_add_to_the_start
    assert_equal START + 90, binder.time(90)
    assert_equal START - 60, binder.time(-60)
    assert_equal (START + 90).utc.iso8601(6), binder.bind("@t:90")
  end

  def test_bind_replaces_symbols_at_any_depth_and_keeps_other_values
    trace = {
      "task_id" => "$task:1",
      "cause_id" => "@event:2",
      "effective_at" => "@t:30",
      "payload" => { "seat_id" => "$seat:builder", "round" => 0, "state" => "working", "ids" => [ "$criterion:a", nil ] }
    }
    bound = binder.bind(trace)
    assert_equal binder.id("$task:1"), bound["task_id"]
    assert_equal binder.event_id(2), bound["cause_id"]
    assert_equal binder.bind("@t:30"), bound["effective_at"]
    assert_equal binder.id("$seat:builder"), bound["payload"]["seat_id"]
    assert_equal 0, bound["payload"]["round"]
    assert_equal "working", bound["payload"]["state"]
    assert_equal [ binder.id("$criterion:a"), nil ], bound["payload"]["ids"]
    assert_equal "$task:1", trace["task_id"], "bind does not change its argument"
  end

  def test_a_trace_in_the_shared_form_validates_and_binds
    trace = minimal_trace
    assert_empty meta_errors("trace", trace)
    event = binder.bind(trace["commands"].first["expect"]["events"].first)
    assert_equal binder.id("$task:1"), event["task_id"]
    assert_equal (START + 5).utc.iso8601(6), event["at"]
  end

  def test_the_trace_form_rejects_a_bare_id_a_number_time_and_an_unknown_field
    bare_id = minimal_trace.tap { |trace| trace["commands"].first["expect"]["events"].first["task_id"] = "task-1" }
    refute_empty meta_errors("trace", bare_id)
    number_time = minimal_trace.tap { |trace| trace["commands"].first["at"] = 5 }
    refute_empty meta_errors("trace", number_time)
    extra = minimal_trace.tap { |trace| trace["commands"].first["expect"]["events"].first["seq"] = 1 }
    refute_empty meta_errors("trace", extra)
  end

  def test_an_unknown_symbol_form_raises
    [ "$task", "$Task:1", "$task:", "@event:0", "@event:x", "@task:1", "@t:1.5", "$task:a-b" ].each do |value|
      assert_raises(ArgumentError, value) { binder.bind(value) }
    end
    assert_raises(ArgumentError) { binder.id("task:1") }
    assert_raises(ArgumentError) { binder.event_id(0) }
  end

  private

  def minimal_trace
    {
      "name" => "00-shape-only",
      "description" => "The smallest trace in the shared form: the owner adds one task.",
      "covers" => [ "meta/trace.schema.json" ],
      "setup" => {
        "settings" => {}, "users" => [ { "id" => "$user:owner" } ], "helpers" => [], "credentials" => [],
        "seats" => [], "projects" => [], "rules" => []
      },
      "commands" => [ {
        "at" => "@t:5", "caller" => "$user:owner", "command" => "add_task", "operation_id" => "add_task",
        "key" => "$key:add", "path_params" => {}, "body" => {},
        "expect" => {
          "outcome" => "completed", "refusal" => nil,
          "events" => [ {
            "ref" => "@event:1", "type" => "task.created", "schema_version" => 1, "at" => "@t:5",
            "effective_at" => "@t:5", "actor_kind" => "owner", "actor_id" => "$user:owner", "project_id" => nil,
            "task_id" => "$task:1", "round" => 0, "subject_kind" => nil, "subject_id" => nil, "cause_id" => nil,
            "command_id" => "$key:add", "payload" => {}
          } ],
          "steps_opened" => [ {
            "task_id" => "$task:1", "kind" => "wait_contract", "step_class" => "waiting", "round" => 0,
            "subject_kind" => nil, "subject_id" => nil, "seat_id" => nil, "cause_kind" => nil,
            "cause_rule_id" => nil, "opening_event_id" => "@event:1"
          } ],
          "steps_closed" => []
        }
      } ]
    }
  end
end
