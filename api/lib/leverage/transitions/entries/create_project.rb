module Leverage
  module Transitions
    module Entries
      class CreateProject < Entry
        def perform(ctx)
          params = ctx.request.params
          Projects.create(ctx, name: params.fetch("name"), goal: params["goal"], budget: params["budget"])
        end
      end
    end
  end
end
