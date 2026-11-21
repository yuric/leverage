# Stands in for Leverage::PendingTransitions, which WP4 writes (milestone 4
# plan §4: WP5 tests against the stubs of the hand-over table and asserts
# that it called them with the right arguments, not what they do). Inside
# the block, PendingTransitions.of answers the given pending transition for
# its task until a cancel of it is recorded, and cancel and reenter record
# their calls and do nothing. Each Call keeps the types of the events the
# command had written when it was made, so a test proves the call came
# before the entry's own events (rule 11: "calls PendingTransitions.cancel
# first").
#
#   calls = with_pending(pending) { owner_run("cancel", "id" => task.id) }
#   assert_equal [ [ :cancel, pending.id, "task_cancelled" ] ], calls.map(&:summary)
module PendingStub
  PT = Leverage::PendingTransitions

  Call = Data.define(:name, :pending, :argument, :keywords, :written_before) do
    # [name, the pending transition's id, the code or the trigger's kind].
    def summary = [ name, pending&.id, argument.respond_to?(:kind) ? argument.kind : argument ]
  end

  # Runs the block with PendingTransitions.of, cancel and reenter replaced;
  # returns the Calls of cancel and reenter, in order. pending may be nil
  # (no task has one).
  def with_pending(pending)
    calls = []
    ended = false
    stubs = {
      of: ->(task) { pending if pending && !ended && task.id == pending.task_id },
      cancel: lambda do |ctx, transition, code, **keywords|
        ended = true
        calls << Call.new(name: :cancel, pending: transition, argument: code, keywords: keywords,
          written_before: ctx.events.map(&:type))
        nil
      end,
      reenter: lambda do |ctx, transition, trigger, **keywords|
        calls << Call.new(name: :reenter, pending: transition, argument: trigger, keywords: keywords,
          written_before: ctx.events.map(&:type))
        nil
      end
    }
    originals = stubs.keys.to_h { |name| [ name, PT.method(name) ] }
    stubs.each { |name, body| PT.define_singleton_method(name, &body) }
    yield
    calls
  ensure
    originals&.each { |name, original| PT.define_singleton_method(name, original) }
  end
end
