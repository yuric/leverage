module Leverage
  module Transitions
    module Entries
      # add_credential (milestone 2 plan IN-22 to IN-24 and milestone 6
      # plan CR-7, CR-29): inserts the credentials row at once, with the id the
      # owner's command supplies, the name, kind and provider, the request's
      # masked label, model, effort and strength rank, and the next
      # position, in state signed_out with no last_verified_at. Until the
      # helper reports every check passed it is not an added credential.
      # It queues run_add_checks for the helper, whose params hold the
      # provider and kind and never the name, and writes no event:
      # credential.added is written by report_request_result.
      #
      # A request with no strength rank adds the credential with rank 1, the
      # seats' default (milestone 3 plan HE-5); the model is the one the
      # request carries (the provider's default the app fills in).
      #
      # A provider must match the kind, and only tokens carry the fixed
      # mask. A second Gemini or Grok login and a used credential id
      # are invalid. Duplicate names are checked within the provider
      # and kind, including adds still running.
      #
      # Params: "credential_id", "kind", "provider", "name", "masked_label",
      # "model", "effort", "strength_rank".
      class AddCredential < Entry
        SINGLE_LOGIN_PROVIDERS = { "gemini" => "Gemini", "grok" => "Grok" }.freeze

        def load(ctx)
          params = ctx.request.params
          @id, @kind, @provider, @name = params.values_at("credential_id", "kind", "provider", "name")
          raise Invalid, "The provider does not offer this credential kind" unless provider_matches_kind?

          validate_model(*params.values_at("model", "effort").map(&:to_s))

          expected_label = @kind == "api_token" ? "••••••••" : nil
          raise Invalid, "The masked label does not match the credential kind" unless params["masked_label"] == expected_label
          @name = Credential.trim_name(@name)
          raise Invalid, "A credential needs a name" if @name.blank?
          if (provider_name = SINGLE_LOGIN_PROVIDERS[@provider]) && existing_login?(ctx)
            raise Invalid, "A Mac holds one #{provider_name} login"
          end
          raise Invalid, "That credential id is taken" if credential_id_taken?(ctx)
        end

        def refusals(ctx)
          causes = [ state_refusal(nil) ]
          if Credential.name_taken?(workspace_id: ctx.workspace.id, kind: @kind, provider: @provider, name: @name)
            causes << Refusal.new(code: "duplicate_name")
          end
          causes.compact
        end

        def perform(ctx)
          params = ctx.request.params
          credential = Credential.create!(id: @id, workspace_id: ctx.workspace.id, kind: @kind, provider: @provider,
            name: @name, masked_label: params["masked_label"], model: params["model"], effort: params["effort"],
            strength_rank: params["strength_rank"] || 1, position: next_position(ctx), state: "signed_out",
            last_verified_at: nil)
          request = SeatRuns.queue(ctx, "run_add_checks", credential_id: credential.id,
            params: { "provider" => @provider, "credential_kind" => @kind })
          @result = { "credential_id" => credential.id, "helper_request_id" => request.id }
        end

        private

        def validate_model(model, effort)
          if @kind == "api_token"
            raise Invalid, "An API token takes no model or effort" unless model.empty? && effort.empty?
            return
          end

          raise Invalid, "A login uses the tool's default for effort" unless effort.empty?

          problem = ModelCatalog.problem(provider: @provider, model: model, effort: effort, native: true)
          raise Invalid, problem if problem
        end

        def provider_matches_kind?
          Contract.registry.fetch("credential_providers")
            .any? { |entry| entry.fetch("provider") == @provider && entry.fetch("kind") == @kind }
        end

        def existing_login?(ctx)
          Credential.exists?(workspace_id: ctx.workspace.id, kind: "login", provider: @provider)
        end

        def credential_id_taken?(ctx)
          @id.nil? || Credential.exists?(id: @id) ||
            Event.exists?(workspace_id: ctx.workspace.id, task_id: nil, type: "credential.removed", subject_id: @id)
        end

        def next_position(ctx)
          Credential.where(workspace_id: ctx.workspace.id).maximum(:position).to_i + 1
        end
      end
    end
  end
end
