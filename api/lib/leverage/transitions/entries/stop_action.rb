module Leverage
  module Transitions
    module Entries
      class StopAction < Entry
        def perform(_ctx)
          raise NotImplementedError, "not built yet"
        end
      end
    end
  end
end
