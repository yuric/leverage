module Leverage
  # The step tracker (PRD, Steps; steps.json): it opens and closes a task's
  # steps from the events EventLog appends, in the same call.
  #
  # First version, by WP1 (milestone 2 plan §4): on_event does nothing.
  # WP4 owns this file from here on and writes the tracker: open, close,
  # the criterion back-fill and the hold interruption.
  module Steps
    module_function

    # Called by EventLog.append for every event it inserts.
    #
    # ctx   - the command's Transitions::Context.
    # event - the Event just inserted.
    def on_event(ctx, event); end
  end
end
