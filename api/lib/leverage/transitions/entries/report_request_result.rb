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
      #   open_sign_in    Sign in again (milestone 3 plan HE-36): as verify.
      #   others          nothing but the request's own row.
      #
      # Milestone 3 (plan HE-2, HE-10, HE-11, HE-29): a passed verify or
      # sign-in of a credential limited with no reset time clears the limit
      # (limited_since), which until the usage readers exist is the reading
      # that shows capacity; a limit with a reset time is left until then
      # (L661). After credential.verified or credential.added the open
      # credential holds are looked at again (Handoff.reevaluate with the
      # credential as verified:, the choice sign_in_again for a sign-in's
      # result), and after credential.signed_out too (signed_out:), for the
      # item of HE-11. What reevaluate closes, switches, opens or resolves
      # is Handoff's.
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
          when "verify", "open_sign_in" then verify(ctx)
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
            added = ctx.emit("credential.added", subject: credential, payload: {})
            Handoff.reevaluate(ctx, cause: added, verified: credential)
          else
            credential.delete
          end
        end

        def verify(ctx)
          return unless credential

          if all_passed?
            confirm(ctx)
            clear_limit_with_no_reset_time
            verified = ctx.emit("credential.verified", subject: credential, payload: {})
            choice = { choice: "sign_in_again" } if @request.kind == "open_sign_in"
            Handoff.reevaluate(ctx, cause: verified, verified: credential, **choice.to_h)
          elsif signed_in_failed?
            credential.update!(state: "signed_out")
            signed_out = ctx.emit("credential.signed_out", subject: credential,
              payload: { seat_id: nil, review_id: nil, job_id: nil })
            Handoff.reevaluate(ctx, cause: signed_out, signed_out: credential)
          end
        end

        def confirm(ctx)
          kept = { "plan" => @report["plan"], "account_email" => @report["account_email"] }.compact
          credential.update!(state: "active", last_verified_at: ctx.at, **kept.symbolize_keys)
        end

        # HE-2: a passed verify or sign-in is the reading that shows
        # capacity for a limit with no reset time; one with a reset time
        # rests until then.
        def clear_limit_with_no_reset_time
          return unless credential.limited_since && credential.limited_until.nil?

          credential.update!(limited_since: nil)
        end
      end
    end
  end
end
