module Leverage
  module Transitions
    # What one command works with inside its transaction (milestone 2 plan
    # §2.1): the request, the workspace row it locked, at (the database
    # clock read once after the lock, shared by every event of the command),
    # and the events written so far. Entries write events through emit.
    class Context
      attr_reader :request, :workspace, :at, :events, :write_seconds

      # The caller the commands row is stored under: the request's, or the
      # user create_owner makes (IN-9).
      attr_accessor :caller_id

      def initialize(request:, workspace:, at:)
        @request = request
        @workspace = workspace
        @at = at
        @caller_id = request.caller_id
        @events = []
        @write_seconds = 0.0
        given = request.by_app? && request.params[Timers::EFFECTIVE_AT]
        @effective_at = given ? [ Time.iso8601(given), at ].min : at
      end

      # create_owner runs before any workspace exists (IN-2): its entry
      # makes the workspace and hands it over, once.
      def use_workspace(workspace)
        raise ArgumentError, "the command already has a workspace" if @workspace

        @workspace = workspace
      end

      # Appends one event through EventLog and returns it. The actor is the
      # request's caller unless named: a seat is ("seat", seat), the owner
      # ("owner", user), the helper ("app", helper) and the app ("app", nil).
      # command_id is the request's key; a timer's events pass none.
      # task: sets task_id, project_id and round (the task's round now)
      # unless they are given; subject: an Active Record row sets
      # subject_kind and subject_id from its class. Inside as_requester the
      # requester is the caller, and cause_id is the one it was given unless
      # the event names its own. In a command the app runs through
      # Timers.apply_workspace, effective_at is the time it was given
      # unless the event names its own.
      def emit(type, **fields)
        fields = { cause_id: @cause_id }.merge(fields) if @cause_id
        fields = { effective_at: effective_at }.merge(fields) unless effective_at == at
        EventLog.append(self, type: type, **fields)
      end

      # Runs the block as the requester of a pending transition (milestone
      # 4 plan §2.1, RE-3): a transition that completes, is refused or is
      # cancelled inside another command or a timer writes its events with
      # its requester as actor, the requester's key as command_id, and
      # cause_id the check.finished or check.overridden that settled it
      # (L241, trace 07). Inside, request answers as the requester's own
      # command did (its caller, key, command and stored params), so
      # actor, request.key and every writer that reads them follow; at,
      # the workspace and events are this command's. The caller's identity
      # comes back after the block, also when it raises.
      #
      # pending   - the PendingTransition.
      # cause_id: - the Event id the events carry as cause_id, or nil.
      #
      # Returns the block's value.
      def as_requester(pending, cause_id:)
        saved = [ @request, @caller_id, @cause_id ]
        @request = Request.new(command: pending.command, workspace_id: pending.workspace_id,
          caller_kind: pending.requester_kind, caller_id: pending.requester_id, key: pending.command_key,
          request_hash: nil, params: pending.params || {})
        @caller_id = pending.requester_id
        @cause_id = cause_id
        yield
      ensure
        @request, @caller_id, @cause_id = saved if saved
      end

      # The time the events of this command take effect: at, or, for a
      # command the app runs through Timers.apply_workspace, the time that
      # call was given (its EFFECTIVE_AT param), never later than at.
      attr_reader :effective_at

      # The actor of the request's caller, as [actor_kind, actor_id].
      def actor
        case request.caller_kind
        when "seat" then [ "seat", request.caller_id ]
        when "owner" then [ "owner", caller_id ]
        when "helper" then [ "app", request.caller_id ]
        else [ "app", nil ]
        end
      end

      # Called by EventLog for each event it inserts.
      def appended(event, seconds)
        @events << event
        @write_seconds += seconds
      end
    end
  end
end
