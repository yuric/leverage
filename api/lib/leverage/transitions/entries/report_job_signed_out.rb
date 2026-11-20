module Leverage
  module Transitions
    module Entries
      # report_job_signed_out (PRD L684, L688, L698, L872; milestone 4 plan
      # RD-40): the helper reports that a job's run found its login signed
      # out. Checked and carried out as report_job_limit, but the login
      # becomes signed out and credential.signed_out is written, naming the
      # seat and the job. Its rows have no side event (state_machine.json),
      # so, unlike report_signed_out, no "Account signed out" item opens here
      # beside another task's hold (HE-11): the next Verify, or that task's
      # own report, finds it.
      #
      # Params: "id" (the credential, from the path) and the SignOutReport
      # body with job_id set.
      class ReportJobSignedOut < ReportJobLimit
        def kind = "signed_out"

        private

        def limit_report = {}
      end
    end
  end
end
