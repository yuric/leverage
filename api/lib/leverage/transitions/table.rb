module Leverage
  module Transitions
    # The commands, each with its entry (milestone 2 plan §2.1, EN-2;
    # milestone 3 plan §2.1): the one list, in six named groups the
    # state-table tests use. An entry is the class
    # Leverage::Transitions::Entries::<Command>, in
    # transitions/entries/<command>.rb, resolved when first used. A command
    # of a later milestone is not here: it has no entry and no route.
    module Table
      # A command with no entry.
      class UnknownCommand < StandardError; end

      TASK_LOOP = %w[
        add_task complete_contract claim acknowledge_briefing acknowledge_review_briefing start_criterion pass_criterion
        submit claim_review release_review pass_review fail_review release heartbeat heartbeat_review cancel
        allow_another_round
      ].freeze
      TIMERS = %w[
        builder_lease_expiry review_lease_expiry command_key_retention credential_hold_release seat_run_placement
      ].freeze
      SIGN_IN = %w[create_owner sign_in sign_out issue_seat_token].freeze
      ACCOUNTS = %w[
        issue_helper_token add_credential verify_credential install_tool connect_seat start_seat stop_seat remove_seat
        report_request_progress report_request_result report_run_started report_run_stopped
      ].freeze
      HANDOFF = %w[report_limit report_signed_out sign_in_again].freeze
      OWNER_CONTROLS = %w[promote edit_contract hold resume pause_seat resume_seat change_seat].freeze
      COMMANDS = (TASK_LOOP + TIMERS + SIGN_IN + ACCOUNTS + HANDOFF + OWNER_CONTROLS).freeze

      @overrides = {}

      class << self
        def include?(command) = COMMANDS.include?(command.to_s)

        def class_name(command)
          "Leverage::Transitions::Entries::#{command.to_s.camelize}"
        end

        # The entry class of a command. Raises UnknownCommand for a command
        # with no entry.
        def entry_for(command)
          command = command.to_s
          return @overrides.fetch(command) if @overrides.key?(command)
          raise UnknownCommand, "#{command} has no entry" unless include?(command)

          class_name(command).constantize
        end

        # Tests only: answers these entries for these commands inside the
        # block, so the pipeline can be proven before the real entries exist.
        def with_entries(entries)
          unknown = entries.keys.map(&:to_s).reject { |command| include?(command) }
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
