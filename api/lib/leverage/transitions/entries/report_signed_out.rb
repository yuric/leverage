module Leverage
  module Transitions
    module Entries
      # report_signed_out (PRD L684, L694-L698; milestone 3 plan §2.1 rules
      # 5 and 6, HE-8, HE-9, HE-11, HE-12): the helper reports that a run
      # found its login signed out. Checked and carried out as report_limit
      # (its refusals, HE-9), but the login becomes signed out and
      # credential.signed_out is written, with the seat. Then the sign-out
      # may leave another task's credential_limit hold with nothing to end
      # it: Handoff.reevaluate opens the "Account signed out" item beside
      # such a hold (HE-11), and closes nothing.
      #
      # Params: "id" (the credential, from the path) and the SignOutReport
      # body: credential_id, seat_id, task_id, review_id, job_id,
      # observed_at, tool_version.
      class ReportSignedOut < ReportLimit
        def kind = "signed_out"

        private

        def limit_report = {}

        def after_hand_over(ctx, first)
          Handoff.reevaluate(ctx, signed_out: @credential, cause: first)
        end
      end
    end
  end
end
