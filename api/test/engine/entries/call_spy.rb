# Records the calls a command makes to a module function of another
# package's seam (milestone 3 plan WP5: Handoff.reevaluate and
# Holds.close_seat_bound), and still runs the real function, so a test
# proves the call and its arguments whatever the function does today.
# Minitest 6 has no stub in its core, so the module's singleton method is
# wrapped for the block and put back afterwards.
#
#   calls = spy_on(Leverage::Handoff, :reevaluate) { report(...) }
#   assert_equal [ verified ], calls.map { |call| call.keywords[:verified] }
module CallSpy
  Call = Data.define(:arguments, :keywords)

  # Runs the block with mod.name wrapped; returns the Calls it saw, in order.
  def spy_on(mod, name)
    calls = []
    original = mod.method(name)
    mod.define_singleton_method(name) do |*arguments, **keywords, &block|
      calls << Call.new(arguments: arguments, keywords: keywords)
      original.call(*arguments, **keywords, &block)
    end
    yield
    calls
  ensure
    mod.define_singleton_method(name, original) if original
  end
end
