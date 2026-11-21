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
      #   others          nothing but the request's own row (read_usage
      #                   included).
      #
      # Milestone 3 (plan HE-2, HE-10, HE-11, HE-29): a passed verify or
      # sign-in of a credential limited with no reset time clears the limit
      # (limited_since). A limit with a reset time can clear early through
      # report_reading (CR-14). After credential.verified or credential.added,
      # Handoff.reevaluate looks at the open holds with the credential as
      # verified: and the choice sign_in_again for a sign-in's result. After
      # credential.signed_out it looks for the HE-11 item with signed_out:.
      #
      # A successful add places the credential and queues its first read
      # (CR-13, CR-29). Verify records a rejected or missing token as
      # signed out (TK-3).
      #
      # A bounded plan or account email of a passed add or verify goes to
      # the credential's row only (IN-25): the stored result holds both as
      # null, and no event carries them. Events are written as the app with
      # the helper's key (the request's caller). A request that has finished
      # or failed is invalid_state, except a request Remove marked failed
      # (CR-31). An unknown one is 404.
      #
      # Params: "id" (the request), "result" (HelperRequestResult).
      class ReportRequestResult < Entry
        UNFINISHED = %w[queued picked_up].freeze
        ACCOUNT_FACT_LIMITS = { "plan" => 40, "account_email" => 254 }.freeze

        def load(ctx)
          @request = HelperRequest.find_by(id: ctx.request.params["id"], workspace_id: ctx.workspace.id)
          raise NotFound, "No such helper request" unless @request

          @report = ctx.request.params["result"]
          raise Invalid, "The report needs a result" unless @report.is_a?(Hash) && @report["checks"].is_a?(Array)
        end

        def refusals(_ctx)
          causes = [ state_refusal(nil) ]
          causes << Refusal.new(code: "invalid_state") unless UNFINISHED.include?(@request.state) || removed_request?
          causes.compact
        end

        def perform(ctx)
          @result = {}
          return if removed_request?

          @request.update!(state: @report["outcome"] == "finished" ? "finished" : "failed", finished_at: ctx.at,
            result: @report.merge("plan" => nil, "account_email" => nil), updated_at: ctx.at)
          case @request.kind
          when "run_add_checks" then add_checks(ctx)
          when "verify", "open_sign_in" then verify(ctx)
          end
        end

        private

        # Remove ends unfinished requests without a result. An ordinary
        # failed report always has a result, even if it had no checks.
        def removed_request?
          @request.state == "failed" && @request.result.nil? && @request.credential_id.present? && @request.finished_at.present?
        end

        def credential
          @credential ||= Credential.find_by(id: @request.credential_id, workspace_id: @request.workspace_id)
        end

        def all_passed?
          checks = @report["checks"]
          @report["outcome"] == "finished" && !checks.empty? && checks.all? { |check| check["passed"] == true }
        end

        def found_signed_out?
          @report["checks"].any? do |check|
            next false unless check["passed"] == false

            if credential.kind == "api_token"
              check["check"] == "token_works" && %w[rejected not_signed_in].include?(check["failure"])
            else
              check["check"] == "signed_in"
            end
          end
        end

        def add_checks(ctx)
          return unless credential
          return if credential.last_verified_at # an added credential is never deleted

          if all_passed?
            confirm(ctx)
            CredentialOrder.new(ctx.workspace.id).place(credential)
            added = ctx.emit("credential.added", subject: credential, payload: {})
            Handoff.reevaluate(ctx, cause: added, verified: credential)
            UsageReads.queue(ctx, [ credential ])
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
          elsif found_signed_out?
            credential.update!(state: "signed_out")
            signed_out = ctx.emit("credential.signed_out", subject: credential,
              payload: { seat_id: nil, review_id: nil, job_id: nil })
            Handoff.reevaluate(ctx, cause: signed_out, signed_out: credential)
          end
        end

        def confirm(ctx)
          kept = @report.slice(*ACCOUNT_FACT_LIMITS.keys).select do |field, value|
            value.is_a?(String) && value.length <= ACCOUNT_FACT_LIMITS.fetch(field)
          end
          credential.update!(state: "active", last_verified_at: ctx.at, **kept.symbolize_keys)
        end

        # HE-2: a passed Verify or Sign in again clears a limit with no
        # reset time, including for a credential without a usage reader.
        def clear_limit_with_no_reset_time
          return unless credential.limited_since && credential.limited_until.nil?

          credential.update!(limited_since: nil)
        end
      end
    end
  end
end
