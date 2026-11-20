module Leverage
  module Rules
    # Red stub (WP3): the rules bound to a hook.
    module Catalog
      Entry = Data.define(:rule, :version)

      module_function

      def at(_workspace_id, _hook) = []

      def enabled(_workspace_id) = []

      def versions(_ids) = []
    end
  end
end
