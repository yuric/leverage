module Leverage
  # The timers (PRD L116-L123; timers.json): which are due for a task, a
  # seat or a workspace, applied each through its own entry before a
  # command's own work (milestone 2 plan §2.1 step 3, EN-14).
  #
  # First version, by WP1 (milestone 2 plan §4): apply_due does nothing.
  # WP5 owns this file from here on.
  module Timers
    module_function

    # Applies every timer due on the request's target task and on every
    # task or review the calling seat holds, with effective_at the due time,
    # actor app, no command_id, and seq before the command's own events.
    #
    # ctx - the command's Transitions::Context.
    #
    # Returns the Events it wrote.
    def apply_due(ctx)
      []
    end
  end
end
