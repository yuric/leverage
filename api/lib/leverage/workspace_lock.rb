module Leverage
  # The workspace lock and the clock read (PRD L217-L219; DB-4, DB-5). The
  # first statement of every transaction that changes anything locks the
  # workspace row, and the lock is held to commit, so the changes of one
  # workspace run one at a time and seq order is commit order. The clock is
  # read by a second statement: a volatile function in the locking
  # statement's own select list can be evaluated before the lock is
  # granted, and at would then be earlier than a commit it follows.
  #
  # The database clock can step back (Docker Desktop's virtual machine on a
  # Mac was seen reading clock_timestamp() 0.59 ms earlier than a moment
  # before). So the time take answers is always later than the at of the
  # workspace's last event, read under the same lock, by one microsecond
  # (timestamptz's resolution) when the clock reads no later: at never
  # decreases as seq grows (L219), no step closes before it opened (L825),
  # and two commands never share an at, which the log audit and Steps read
  # as one command's.
  module WorkspaceLock
    # The advisory lock key setup takes while no workspace row exists yet
    # (milestone 2 plan IN-2): "leve" in ASCII.
    SETUP_KEY = 0x6c657665
    # The resolution of a timestamptz.
    TICK = Rational(1, 1_000_000)

    module_function

    # Locks the workspace row and reads the database clock, never earlier
    # than one microsecond after the workspace's last event.
    #
    # Returns [Workspace, Time]. Raises ActiveRecord::RecordNotFound for an
    # unknown workspace.
    def take(workspace_id)
      workspace = Workspace.lock("FOR UPDATE").find(workspace_id)
      now = clock
      last = last_at(workspace)
      floor = last && (last + TICK)
      [ workspace, floor && floor > now ? floor : now ]
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

    # The at of the locked workspace's last event (workspaces.last_seq),
    # or nil before its first.
    def last_at(workspace)
      return if workspace.last_seq.zero?

      Event.where(workspace_id: workspace.id, seq: workspace.last_seq).pick(:at)
    end
  end
end
