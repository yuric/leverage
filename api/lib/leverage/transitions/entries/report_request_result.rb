module Leverage
  module Transitions
    module Entries
      # report_request_result (PRD L600-L608; milestone 2 plan IN-23 to
      # IN-25, CL-18): the helper reports a request's outcome. The request
      # becomes finished or failed, as reported, with finished_at and the
      # result. Then, by kind:
      #
      #   run_add_checks  every check passed (at least one reported, the
      #                   outcome finished): the credential becomes active,
      #                   last_verified_at is set and credential.added is
      #                   written. Anything else deletes the row, which was
      #                   never an added credential (IN-24).
      #   verify          every check passed: active, last_verified_at and
      #                   credential.verified. The signed_in check failed:
      #                   signed_out and credential.signed_out. Any other
      #                   failure: nothing.
      #   others          nothing but the request's own row.
      #
      # A non-null plan or account email of a passed add or verify goes to
      # the credential's row only (IN-25): the stored result holds both as
      # null, and no event carries them. Events are written as the app with
      # the helper's key (the request's caller). A request that has finished
      # or failed is invalid_state; an unknown one 404.
      #
      # Params: "id" (the request), "result" (HelperRequestResult).
      class ReportRequestResult < Entry
        UNFINISHED = %w[queued picked_up].freeze

        def load(ctx)
          @request = HelperRequest.find_by(id: ctx.request.params["id"], workspace_id: ctx.workspace.id)
          raise NotFound, "No such helper request" unless @request

          @report = ctx.request.params["result"]
          raise Invalid, "The report needs a result" unless @report.is_a?(Hash) && @report["checks"].is_a?(Array)
        end

        def refusals(_ctx)
          causes = [ state_refusal(nil) ]
          causes << Refusal.new(code: "invalid_state") unless UNFINISHED.include?(@request.state)
          causes.compact
        end

        def perform(ctx)
          @request.update!(state: @report["outcome"] == "finished" ? "finished" : "failed", finished_at: ctx.at,
            result: @report.merge("plan" => nil, "account_email" => nil), updated_at: ctx.at)
          case @request.kind
          when "run_add_checks" then add_checks(ctx)
          when "verify" then verify(ctx)
          end
          @result = {}
        end

        private

        def credential
          @credential ||= Credential.find_by(id: @request.credential_id, workspace_id: @request.workspace_id)
        end

        def all_passed?
          checks = @report["checks"]
          @report["outcome"] == "finished" && !checks.empty? && checks.all? { |check| check["passed"] == true }
        end

        def signed_in_failed?
          @report["checks"].any? { |check| check["check"] == "signed_in" && check["passed"] == false }
        end

        def add_checks(ctx)
          return unless credential
          return if credential.last_verified_at # an added credential is never deleted

          if all_passed?
            confirm(ctx)
            ctx.emit("credential.added", subject: credential, payload: {})
          else
            credential.delete
          end
        end

        def verify(ctx)
          return unless credential

          if all_passed?
            confirm(ctx)
            ctx.emit("credential.verified", subject: credential, payload: {})
          elsif signed_in_failed?
            credential.update!(state: "signed_out")
            ctx.emit("credential.signed_out", subject: credential, payload: { seat_id: nil, review_id: nil, job_id: nil })
          end
        end

        def confirm(ctx)
          kept = { "plan" => @report["plan"], "account_email" => @report["account_email"] }.compact
          credential.update!(state: "active", last_verified_at: ctx.at, **kept.symbolize_keys)
        end
      end
    end
  end
end
