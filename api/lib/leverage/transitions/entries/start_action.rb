module Leverage
  module Transitions
    module Entries
      class StartAction < Entry
        def perform(_ctx)
          raise NotImplementedError, "not built yet"
        end
      end
    end
  end
end
