# The base class of a test that needs real commits (milestone 2 plan
# EN-26): a long poll, a read snapshot, two connections racing for the
# workspace lock. Transactional tests are off, so every statement commits;
# each test gets a fresh workspace of its own through Scenario and leaves
# its rows behind (events cannot be deleted, and each parallel worker has a
# database of its own).
class CommittingTestCase < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup { @scenario = Scenario.new }

  attr_reader :scenario
end
