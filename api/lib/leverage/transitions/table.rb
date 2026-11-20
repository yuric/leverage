module Leverage
  module Transitions
    # The commands milestone 2 has, each with its entry (milestone 2 plan
    # §2.1, EN-2): the one list, in four named groups the state-table tests
    # use. An entry is the class Leverage::Transitions::Entries::<Command>,
    # in transitions/entries/<command>.rb, resolved when first used. A
    # command of a later milestone is not here: it has no entry and no
    # route.
    #
    # While milestone 3 is built (its plan, HT-6), its twelve new entries
    # wait in PENDING: entry_for, known? and with_entries find them, so a
    # command, a timer and the tests of the packages that write them do;
    # include?, COMMANDS and every walk of the table (the state-table tests,
    # golden traces) do not, so those stay green until WP10 moves them into
    # their groups and deletes PENDING.
    module Table
      # A command with no entry.
      class UnknownCommand < StandardError; end

      TASK_LOOP = %w[
        add_task complete_contract claim acknowledge_briefing acknowledge_review_briefing start_criterion pass_criterion
        submit claim_review release_review pass_review fail_review release heartbeat heartbeat_review cancel
        allow_another_round
      ].freeze
      TIMERS = %w[builder_lease_expiry review_lease_expiry command_key_retention].freeze
      SIGN_IN = %w[create_owner sign_in sign_out issue_seat_token].freeze
      ACCOUNTS = %w[
        issue_helper_token add_credential verify_credential install_tool connect_seat start_seat stop_seat remove_seat
        report_request_progress report_request_result report_run_started report_run_stopped
      ].freeze
      COMMANDS = (TASK_LOOP + TIMERS + SIGN_IN + ACCOUNTS).freeze

      # Milestone 3's entries by the group WP10 moves each into: two new
      # groups, and two timers for TIMERS (milestone 3 plan §2.1).
      PENDING_GROUPS = {
        "HANDOFF" => %w[report_limit report_signed_out sign_in_again].freeze,
        "TIMERS" => %w[credential_hold_release seat_run_placement].freeze,
        "OWNER_CONTROLS" => %w[promote edit_contract hold resume pause_seat resume_seat change_seat].freeze
      }.freeze
      PENDING = PENDING_GROUPS.values.flatten.freeze

      @overrides = {}

      class << self
        def include?(command) = COMMANDS.include?(command.to_s)

        # Whether the command has an entry: served (include?) or pending.
        def known?(command) = include?(command) || PENDING.include?(command.to_s)

        def class_name(command)
          "Leverage::Transitions::Entries::#{command.to_s.camelize}"
        end

        # The entry class of a command, served or pending. Raises
        # UnknownCommand for a command with no entry.
        def entry_for(command)
          command = command.to_s
          return @overrides.fetch(command) if @overrides.key?(command)
          raise UnknownCommand, "#{command} has no entry" unless known?(command)

          class_name(command).constantize
        end

        # Tests only: answers these entries for these commands inside the
        # block, so the pipeline can be proven before the real entries exist.
        def with_entries(entries)
          unknown = entries.keys.map(&:to_s).reject { |command| known?(command) }
          raise UnknownCommand, "commands with no entry: #{unknown.join(", ")}" unless unknown.empty?

          saved = @overrides
          @overrides = saved.merge(entries.transform_keys(&:to_s))
          yield
        ensure
          @overrides = saved if saved
        end
      end
    end
  end
end
