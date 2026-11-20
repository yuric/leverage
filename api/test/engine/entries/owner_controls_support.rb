require_relative "accounts_support"

# What the tests of the owner controls share (milestone 3 plan WP6): the
# requests of AccountsSupport, the events one command wrote, and a recorder
# for the calls an entry makes to a seam another package finishes
# (Holds.close_seat_bound is WP4's, Handoff.reevaluate WP3's): the entry is
# tested for calling it with the right arguments, as handoff.rb asks.
# Every value is made up.
module OwnerControlsSupport
  include AccountsSupport

  # The events the command with this key wrote, in seq order.
  def written_by(key) = Event.where(workspace_id: scenario.workspace_id, command_id: key).order(:seq).to_a

  # Runs an owner command with a new key; returns [outcome, events it wrote].
  def owner_run(command, params = {})
    key = new_key
    outcome = owner_command(command, params, key: key)
    [ outcome, written_by(key) ]
  end

  # Records each call of mod.name inside the block, as [args, keywords],
  # and still calls the real method. Returns the calls.
  def recording(mod, name)
    calls = []
    original = mod.method(name)
    mod.define_singleton_method(name) do |*args, **keywords|
      calls << [ args, keywords ]
      original.call(*args, **keywords)
    end
    yield
    calls
  ensure
    mod.define_singleton_method(name, original)
  end

  # A Working task the builder holds, with its lease running.
  def working_task(builder, **options) = scenario.task(state: "working", builder: builder, **options)

  # A hold opened by the app through Holds, as Scenario#hold does.
  def open_hold(task, reason, **options) = scenario.hold(task, reason: reason, **options)

  def open_holds(task) = Leverage::Holds.open_holds(task.reload)
end
