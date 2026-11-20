# Turns the state_machine.json rows of a list of commands into test cases
# (test 3, PRD L836; milestone 2 plan WP1). For a command whose rows read a
# task's state, there is one case per task state: one for each row from
# that state (one per guard combination), or one that expects
# invalid_state when no row starts there. A command whose rows read no
# state (from: null) has one case per row. Nothing is typed here: the rows
# come from Leverage::Contract.
#
#   class StateTableTest < ActiveSupport::TestCase
#     StateTableCases.define(self, Leverage::Transitions::Table::TASK_LOOP) do |kase|
#       # build kase.from with Scenario, apply kase.command, then
#       kase.invalid_state? ? assert_refused("invalid_state") : assert_events(kase.events)
#     end
#   end
module StateTableCases
  # row is the state_machine.json row, or nil for an invalid_state case.
  Case = Data.define(:command, :from, :row) do
    def invalid_state? = row.nil?
    def guard = row ? row.fetch("guard") : []
    def to = row&.fetch("to")
    def refusal = row ? row.fetch("refusal") : Leverage::Contract.state_machine.fetch("unlisted_pair_refusal")
    def events = row ? row.fetch("events") : []
    def conditional_events = row ? row.fetch("conditional_events") : []
    def hook = row&.fetch("hook")
    def builder_lease = row&.fetch("builder_lease")
    def who = row ? row.fetch("who") : []
    def not_served? = false
    def expected_refusal = refusal

    def name
      from_text = from.nil? ? "no state" : from
      if invalid_state?
        "#{command} from #{from_text} is #{refusal}"
      else
        guards = guard.empty? ? "" : " when #{guard.join(" and ")}"
        target = refusal ? "refused #{refusal}" : "to #{to.nil? ? "no state" : to}"
        "#{command} from #{from_text}#{guards} #{target}"
      end
    end
  end

  module_function

  def rows(command)
    Leverage::Contract.state_machine.fetch("groups").flat_map { |group| group.fetch("rows") }
      .select { |row| row.fetch("command") == command }
  end

  def for(commands)
    states = Leverage::Contract.list("task_states")
    commands.flat_map do |command|
      command_rows = rows(command)
      raise ArgumentError, "#{command} has no row in state_machine.json" if command_rows.empty?

      if command_rows.all? { |row| row.fetch("from").nil? }
        command_rows.map { |row| Case.new(command: command, from: nil, row: row) }
      else
        states.flat_map do |state|
          from_state = command_rows.select { |row| row.fetch("from") == state }
          if from_state.empty?
            [ Case.new(command: command, from: state, row: nil) ]
          else
            from_state.map { |row| Case.new(command: command, from: state, row: row) }
          end
        end
      end
    end
  end

  # Defines one test per case on test_class; the block runs as the test,
  # with the case as its argument.
  def define(test_class, commands, &body)
    self.for(commands).each do |kase|
      test_class.test("state table: #{kase.name}") { instance_exec(kase, &body) }
    end
  end
end
