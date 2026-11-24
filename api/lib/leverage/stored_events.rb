module Leverage
  # How readers take a stored event whose spelling has since changed (DB-52).
  # The log is append-only, so events written before a rename keep the old
  # name. Every reader of a stored payload goes through here, so each old
  # spelling is mapped in one place.
  #
  # Only reads of stored events use it. New events are validated against the
  # payload schemas, which name only the new spelling (EventLog#append).
  module StoredEvents
    # The task state before the rename: task.created's state said
    # "imaginarium" until DB-52 renamed it "ideas".
    RENAMED_TASK_STATES = { "imaginarium" => "ideas" }.freeze

    # A task state as a stored event spells it, in today's spelling. Any
    # other value, nil included, passes through, so each reader keeps its
    # own strictness about a missing state.
    def self.task_state(state) = RENAMED_TASK_STATES.fetch(state, state)

    # Whether a stored project.created says it made the Imaginarium project
    # (DB-53). One written before the field has none, which reads as false.
    def self.imaginarium(flag) = flag == true
  end
end
