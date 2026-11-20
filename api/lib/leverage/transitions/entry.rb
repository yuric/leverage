module Leverage
  module Transitions
    # The base class of an entry: one command's part of the transition
    # function (milestone 2 plan §2.1). The pipeline makes one entry per
    # request and calls, in order:
    #
    #   load(ctx)      finds the rows the command is about; raises NotFound
    #                  (404) for an id outside the caller's workspace or
    #                  Invalid (422) for what the contract's shape rules
    #                  refuse (IN-13). Writes nothing.
    #   refusals(ctx)  every refusal cause that applies, as Refusals or
    #                  codes; Precedence picks the first. Writes nothing.
    #   hook           the hook of the state-table row the command runs, or
    #                  nil; Gate asks gating there.
    #   gate_request_fields(ctx)  what gating needs to know at the hook.
    #   perform(ctx)   changes rows through the models and writes events
    #                  through ctx.emit; sets @result (the token-free
    #                  result) and @once (a token shown once, IN-11).
    #
    # The state check comes from state_machine.json through state_row and
    # state_refusal, never retyped.
    class Entry
      # The command the class is the entry of, from its name:
      # Entries::AllowAnotherRound is allow_another_round.
      def self.command
        name&.demodulize&.underscore
      end

      attr_reader :command, :result, :once

      def initialize(command = self.class.command)
        @command = command
        @row = nil
      end

      def load(_ctx); end

      def refusals(_ctx) = []

      def hook = @row&.fetch("hook")

      def perform(_ctx)
        raise NotImplementedError, "#{self.class} does not perform #{command}"
      end

      # The fields of Gating::Request that only the entry knows: task_id,
      # project_id, round, subject_kind, subject_id and the hook's hashed
      # inputs. Gating::NoRules reads none of them.
      def gate_request_fields(_ctx)
        { task_id: nil, project_id: nil, round: nil, subject_kind: nil, subject_id: nil, inputs: {} }
      end

      # The command's state-table rows.
      def rows
        @rows ||= Contract.state_machine.fetch("groups").flat_map { |group| group.fetch("rows") }
          .select { |row| row.fetch("command") == command }
      end

      # The row for a from-state (nil for a command that reads none) whose
      # guards all hold, or nil when none starts there. Remembered: hook
      # reads it.
      def state_row(from, true_guards = [])
        holding = true_guards.map(&:to_s)
        @row = rows.find { |row| row.fetch("from") == from && (row.fetch("guard") - holding).empty? }
      end

      # The refusal the state table gives: invalid_state when no row starts
      # at from, the row's own refusal for a refused row, else nil.
      def state_refusal(from, true_guards = [])
        row = state_row(from, true_guards)
        return Refusal.new(code: Contract.state_machine.fetch("unlisted_pair_refusal")) unless row

        row.fetch("refusal") && Refusal.new(code: row.fetch("refusal"))
      end
    end
  end
end
