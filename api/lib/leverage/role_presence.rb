module Leverage
  # Whether a role that claims jobs is online (PRD L401; milestone 4 plan
  # §2.1, The orchestrator's presence, RD-15): some enabled, not paused, not
  # removed seat of the role polled within the last 90 seconds, and either
  # connects on its own or has an available candidate. Since when it is not,
  # and the account that is the cause. Reads only.
  #
  # First version (milestone 4 plan §4, the hand-over table): every role is
  # online, offline since nil, and no account is the cause. WP7 writes it.
  module RolePresence
    # The seconds after a seat's last poll at which it stops counting
    # (L401). Not set yet: WP7 writes it.
    OFFLINE_AFTER = nil

    module_function

    # The time the role has been online since, or nil while it is offline.
    # Not written yet: WP7 writes it.
    def online_since(workspace, role, at)
      nil
    end

    # workspace - a Workspace; role - "orchestrator" or "planner"; at - a
    # Time.
    def online?(workspace, role, at)
      true
    end

    # The time the role went offline, or nil while it is online.
    def offline_since(workspace, role, at)
      nil
    end

    # The Credential that is the cause when every seat of the role is held
    # back by its own account (limited or signed out), else nil.
    def cause_credential(workspace, role, at)
      nil
    end
  end
end
