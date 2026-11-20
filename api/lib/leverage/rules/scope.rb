module Leverage
  module Rules
    # Red stub (WP3): whether a version's fixed scope covers a task.
    module Scope
      module_function

      def coverage(_version, _task, _inputs = nil) = :covers

      def covers?(_version, _task, _inputs = nil) = true
    end
  end
end
