module Leverage
  module Transitions
    # One command as the transition function receives it (milestone 2 plan
    # §2.1). caller_kind is "seat", "owner" or "helper" (registry
    # lists.caller_kinds), or nil for the app's own commands (a timer, the
    # sweep), which carry no key and store no commands row. caller_id is the
    # seat, the owner's user or the helper; create_owner has none until its
    # entry makes the user. request_hash is Idempotency.request_hash of the
    # HTTP request; params is the body the controller checked, with string
    # keys, plus the path's ids.
    Request = Data.define(:command, :workspace_id, :caller_kind, :caller_id, :key, :request_hash, :params) do
      def initialize(command:, workspace_id:, caller_kind:, caller_id:, key:, request_hash:, params: {})
        super(command: command.to_s, workspace_id: workspace_id, caller_kind: caller_kind&.to_s, caller_id: caller_id,
              key: key, request_hash: request_hash, params: params.to_h.deep_stringify_keys.freeze)
      end

      # The app runs this command: no caller, no key, no commands row.
      def by_app? = caller_kind.nil?
    end
  end
end
