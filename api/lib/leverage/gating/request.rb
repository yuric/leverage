module Leverage
  module Gating
    # What the transition function asks gating to decide: a command reaching a
    # hook. subject_kind is a check subject kind (registry
    # lists.check_subject_kinds) or nil; requester_kind is an actor kind;
    # command_key is the requester's idempotency key, nil at action.requested;
    # inputs are the hook's hashed inputs (hooks.json), deep-frozen.
    Request = Data.define(:workspace_id, :task_id, :project_id, :hook, :round, :subject_kind, :subject_id,
                          :requester_kind, :requester_id, :command_key, :inputs) do
      def initialize(inputs:, **fields)
        super(inputs: deep_freeze(inputs), **fields)
      end

      private

      def deep_freeze(value)
        case value
        when Hash then value.to_h { |key, item| [ deep_freeze(key), deep_freeze(item) ] }.freeze
        when Array then value.map { |item| deep_freeze(item) }.freeze
        when String then value.frozen? ? value : value.dup.freeze
        else value
        end
      end
    end
  end
end
