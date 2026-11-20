module Leverage
  module Rules
    # Red stub (WP3): the provider rule.
    module ProviderRule
      Account = Data.define(:provider, :credential)

      module_function

      def on?(_task) = false

      def allowed?(_task_id, _provider) = true

      def refuses?(_seat, _task) = false

      def review_provider(_seat) = nil

      def review_account(_seat, _at) = nil

      def may_review_now?(_seat, _task, _at) = false
    end
  end
end
