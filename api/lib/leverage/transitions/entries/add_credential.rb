module Leverage
  module Transitions
    module Entries
      # add_credential (PRD L595-L609; milestone 2 plan IN-22 to IN-24,
      # CL-20, SC-5): inserts the credentials row at once, with the id the
      # owner's command supplies, the name, kind and provider, the request's
      # masked label, model, effort and strength rank, and the next
      # position, in state signed_out with no last_verified_at. Until the
      # helper reports every check passed it is not an added credential.
      # It queues run_add_checks for the helper, whose params hold the
      # provider and kind and never the name, and writes no event:
      # credential.added is written by report_request_result.
      #
      # Only logins of the four login providers in this milestone: an API
      # token (SC-5), a login of an API provider, a second Gemini login
      # (CL-20) and an id that is already a credential are 422 invalid. A
      # name already used within its provider and kind, also by an add that
      # still runs, is refused duplicate_name.
      #
      # Params: "credential_id", "kind", "provider", "name", "masked_label",
      # "model", "effort", "strength_rank".
      class AddCredential < Entry
        def load(ctx)
          params = ctx.request.params
          @id, @kind, @provider, @name = params.values_at("credential_id", "kind", "provider", "name")
          raise Invalid, "API tokens are added from milestone 6 on" if @kind == "api_token"
          raise Invalid, "#{@provider.inspect} is not a login provider" unless login_provider?
          raise Invalid, "A credential needs a name" unless @name.is_a?(String) && !@name.empty?
          raise Invalid, "A Mac holds one Gemini login" if @provider == "gemini" && gemini_login?(ctx)
          raise Invalid, "That credential id is taken" if @id.nil? || Credential.exists?(id: @id)
        end

        def refusals(ctx)
          causes = [ state_refusal(nil) ]
          if Credential.exists?(workspace_id: ctx.workspace.id, kind: @kind, provider: @provider, name: @name)
            causes << Refusal.new(code: "duplicate_name")
          end
          causes.compact
        end

        def perform(ctx)
          params = ctx.request.params
          credential = Credential.create!(id: @id, workspace_id: ctx.workspace.id, kind: @kind, provider: @provider,
            name: @name, masked_label: params["masked_label"], model: params["model"], effort: params["effort"],
            strength_rank: params["strength_rank"], position: next_position(ctx), state: "signed_out",
            last_verified_at: nil)
          request = SeatRuns.queue(ctx, "run_add_checks", credential_id: credential.id,
            params: { "provider" => @provider, "credential_kind" => @kind })
          @result = { "credential_id" => credential.id, "helper_request_id" => request.id }
        end

        private

        def login_provider?
          @kind == "login" && Contract.registry.fetch("credential_providers")
            .any? { |entry| entry.fetch("provider") == @provider && entry.fetch("kind") == "login" }
        end

        def gemini_login?(ctx)
          Credential.exists?(workspace_id: ctx.workspace.id, kind: "login", provider: "gemini")
        end

        def next_position(ctx)
          Credential.where(workspace_id: ctx.workspace.id).maximum(:position).to_i + 1
        end
      end
    end
  end
end
