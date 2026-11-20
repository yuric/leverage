# What the tests of the commands that end a reviewer's or a seat's waiting
# command share (milestone 4 plan WP5b, §2.1 rule 11): a recorder for the
# call these commands make to PendingTransitions.cancel, and the lookup of
# a task's pending transition, so that a test proves the call, the code it
# gives, and that it comes before the command's own events whatever the
# finished PendingTransitions does (the method itself is WP4's; its own
# test holds what the call does). Every value is made up.
module PendingEndsSupport
  # One call of PendingTransitions.cancel: the transition's id, the code,
  # and the types of the events the command had written when it was
  # called, in order.
  Cancelled = Data.define(:pending_id, :code, :events_before)

  # Runs the block with PendingTransitions.of reading the task's pending
  # row and PendingTransitions.cancel recording its call and marking the row
  # cancelled (as the finished method does, so a second look at the task
  # finds nothing). Both are put back afterwards. Returns the Cancelled
  # calls, in order.
  def recording_cancels
    calls = []
    mod = Leverage::PendingTransitions
    original_of = mod.method(:of)
    original_cancel = mod.method(:cancel)
    mod.define_singleton_method(:of) { |task| PendingTransition.find_by(task_id: task.id, state: "pending") }
    mod.define_singleton_method(:cancel) do |ctx, pending, code, **_timer|
      calls << Cancelled.new(pending.id, code, ctx.events.map(&:type))
      pending.update_columns(state: "cancelled", params: nil)
      nil
    end
    yield
    calls
  ensure
    mod.define_singleton_method(:of, original_of) if original_of
    mod.define_singleton_method(:cancel, original_cancel) if original_cancel
  end
end
