module Leverage
  module Rules
    # The provider rule, "A different provider reviews every task" (PRD
    # L441, L448, L670, L912-L913; milestone 4 plan §2.1, RD-50, RD-51). It
    # reads only.
    #
    # The rule is on for a task while an enabled, not removed rule with the
    # function refuse_reviewer_of_building_provider is at review.assign and
    # its fixed scope covers the task; it is then the one reading of
    # provider_allowed?. The provider compared is that of the account the
    # review would run on (RD-50): the account the reviewer's run is on
    # (seats.run_credential_id, M3 HD-3), which is the one its claim
    # records, or the seat's own provider for a seat that connects on its
    # own.
    module ProviderRule
      FUNCTION = "refuse_reviewer_of_building_provider".freeze
      HOOK = "review.assign".freeze

      # The account a review would run on: its provider, and the credential
      # (nil for a seat that connects on its own).
      Account = Data.define(:provider, :credential)

      module_function

      # Whether the rule is on and covers the task.
      def on?(task)
        Catalog.at(task.workspace_id, HOOK).any? do |entry|
          entry.version.checker_function == FUNCTION && Scope.covers?(entry.version, task)
        end
      end

      # Whether a reviewer, or a review's credential, of provider (a
      # credential_providers value) may work on the task's review. Always
      # true while the rule is off, and for a task that does not exist.
      def allowed?(task_id, provider)
        task = Task.find_by(id: task_id)
        return true unless task && on?(task)

        !ProviderRecord.groups(task.id).include?(ProviderRecord.group(provider))
      end

      # Whether the rule keeps the task's review from the seat now, judged
      # on the account its run is on.
      def refuses?(seat, task)
        !allowed?(task.id, review_provider(seat))
      end

      # The provider of the account the seat's review would run on: its
      # run's credential, or the seat's own provider when it connects on
      # its own (RD-50).
      def review_provider(seat)
        credential_id = SeatRuns.run_credential_id(seat)
        return seat.provider unless credential_id

        Credential.where(workspace_id: seat.workspace_id, id: credential_id).pick(:provider) || seat.provider
      end

      # The account the seat's review would run on at time at, or nil when
      # it has none (RD-51): a seat that connects on its own reviews on its
      # own provider; a seat the app runs on its run's credential while that
      # is available, else on the first available candidate, where the app
      # places a run that holds nothing (M3 HD-4, Candidates rule 2). A seat
      # whose accounts are all limited or signed out has none.
      def review_account(seat, at)
        return Account.new(provider: seat.provider, credential: nil) unless seat.credential_id

        run = Credential.find_by(workspace_id: seat.workspace_id, id: SeatRuns.run_credential_id(seat))
        credential = run if run && Candidates.available?(run, at)
        credential ||= Candidates.first_available(seat, nil, at)
        credential && Account.new(provider: credential.provider, credential: credential)
      end

      # Whether the seat has, at time at, an account to review the task on
      # that the rule allows: what "No reviewer is eligible" asks of each
      # connected reviewer (RD-51), besides that it never held the task.
      def may_review_now?(seat, task, at)
        account = review_account(seat, at)
        !account.nil? && allowed?(task.id, account.provider)
      end
    end
  end
end
