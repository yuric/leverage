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
      # subject_kind and subject_id from its class.
      def emit(type, **fields)
        EventLog.append(self, type: type, **fields)
      end

      # The actor of the request's caller, as [actor_kind, actor_id].
      def actor
        case request.caller_kind
        when "seat" then [ "seat", request.caller_id ]
        when "owner" then [ "owner", caller_id ]
        when "helper" then [ "app", request.caller_id ]
        else [ "app", nil ]
        end
      end

      # Empty symbol for the red run (milestone 4 plan WP1).
      def as_requester(_pending, cause_id:)
        yield
      end

      # Called by EventLog for each event it inserts.
      def appended(event, seconds)
        @events << event
        @write_seconds += seconds
      end
    end
  end
end
