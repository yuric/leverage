module Leverage
  # The workspace lock and the clock read (PRD L217-L218; DB-4, DB-5). The
  # first statement of every transaction that changes anything locks the
  # workspace row, and the lock is held to commit, so the changes of one
  # workspace run one at a time and seq order is commit order. The clock is
  # read by a second statement: a volatile function in the locking
  # statement's own select list can be evaluated before the lock is
  # granted, and at would then be earlier than a commit it follows.
  module WorkspaceLock
    # The advisory lock key setup takes while no workspace row exists yet
    # (milestone 2 plan IN-2): "leve" in ASCII.
    SETUP_KEY = 0x6c657665

    module_function

    # Locks the workspace row and reads the database clock.
    #
    # Returns [Workspace, Time]. Raises ActiveRecord::RecordNotFound for an
    # unknown workspace.
    def take(workspace_id)
      workspace = Workspace.lock("FOR UPDATE").find(workspace_id)
      [ workspace, clock ]
    end

    # For create_owner, which runs before any workspace exists: a fixed
    # transaction-level advisory lock, then the clock. Returns the Time.
    def take_setup
      Workspace.connection.execute("SELECT pg_advisory_xact_lock(#{SETUP_KEY})")
      clock
    end

    def clock
      Workspace.connection.select_value("SELECT clock_timestamp()")
    end
  end
end
