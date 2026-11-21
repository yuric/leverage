require "digest"

module Leverage
  # Idempotency keys and the commands table (PRD L220, L486, L818; IF-4,
  # DB-34; milestone 2 plan IN-8, IN-9, IN-11). Every mutating call carries
  # a key; the commands row of (caller kind, caller id, key) holds the
  # request's hash and its outcome, a refusal included, and a repeat is
  # answered from it without running anything.
  module Idempotency
    # The same key with a different request: 422 key_reused (IF-3).
    class KeyReused < StandardError; end

    # IN-8: 1 to 128 characters of letters, digits, hyphens and underscores.
    KEY = /\A[A-Za-z0-9_-]{1,128}\z/

    module_function

    def valid_key?(key)
      key.is_a?(String) && KEY.match?(key)
    end

    # SHA-256 hex over the method, the path and the raw body bytes (IN-8):
    # not a canonical JSON form, because bodies carry decimal money that the
    # canonical form refuses. without: names top-level body fields left
    # out, so that an unsalted hash of a password is never stored (IN-9);
    # the body is then parsed and generated again without them.
    def request_hash(method:, path:, body:, without: [])
      bytes = body.to_s
      unless without.empty?
        parsed = JSON.parse(bytes)
        bytes = JSON.generate(parsed.except(*without)) if parsed.is_a?(Hash)
      end
      Digest::SHA256.hexdigest("#{method.to_s.upcase}\n#{path}\n#{bytes}")
    rescue JSON::ParserError
      Digest::SHA256.hexdigest("#{method.to_s.upcase}\n#{path}\n#{body}")
    end

    # The stored outcome of the request's key, or nil when the key is new.
    # Runs under the workspace lock, so a concurrent first call has either
    # committed its row or not started. Raises KeyReused when the row's hash
    # differs.
    def find(request, at: nil)
      return nil if request.by_app? || request.caller_id.nil?

      row = Command.find_by(caller_kind: request.caller_kind, caller_id: request.caller_id, key: request.key)
      return nil unless row
      raise KeyReused, "This key was used for another request" unless row.request_hash == request.request_hash

      outcome_of(row, at: at)
    end

    # Writes the commands row of a completed or refused command. once is
    # never stored: the row's check constraint also refuses any key named
    # token or ending in _token.
    def store(ctx, request, outcome)
      Command.create!(workspace_id: ctx.workspace.id, caller_kind: request.caller_kind, caller_id: ctx.caller_id,
        key: request.key, command: request.command, request_hash: request.request_hash, outcome: outcome.outcome.to_s,
        refusal: outcome.refusal&.to_h, result: outcome.result)
    end

    def forget_task_claims(task)
      receipts = completed_claims(task.workspace_id)
      receipts.where(command: "claim_job").where("result -> 'input' ->> 'task_id' = ?", task.id)
        .update_all("result = result - 'input'")
      receipts.where(command: "claim").where("result -> 'task' ->> 'id' = ?", task.id)
        .update_all("result = jsonb_build_object('task', jsonb_build_object('id', result -> 'task' -> 'id'))")
      receipts.where(command: "claim_review").where("result -> 'review' ->> 'task_id' = ?", task.id)
        .update_all("result = jsonb_build_object('review', jsonb_build_object('id', result -> 'review' -> 'id', " \
          "'task_id', result -> 'review' -> 'task_id'))")
    end

    def forget_project_claims(project)
      receipts = completed_claims(project.workspace_id)
      receipts.where(command: "claim_job")
        .where("result -> 'input' ->> 'project_id' = ?", project.id).update_all("result = result - 'input'")
      receipts.where(command: %w[claim claim_review]).where(
        "result -> 'briefing' -> 'brief' @> ?::jsonb", [ { project_id: project.id } ].to_json
      ).update_all("result = jsonb_set(result, '{briefing,brief}', '[]'::jsonb)")
    end

    def outcome_of(row, at: nil)
      if row.outcome == "completed" && !claim_material_available?(row, at)
        return Transitions::Outcome.refused(Transitions::Refusal.new(code: "not_eligible"))
      end

      refusal = row.refusal && Transitions::Refusal.new(**row.refusal.symbolize_keys)
      Transitions::Outcome.new(outcome: row.outcome, result: row.result, refusal: refusal, once: nil)
    end

    def claim_material_available?(row, at)
      return !work_claim_deleted?(row) if %w[claim claim_review].include?(row.command)
      return true unless row.command == "claim_job"
      return false unless row.result&.key?("input")

      seat = Seat.find_by(id: row.caller_id, workspace_id: row.workspace_id)
      job = Job.find_by(id: row.result["job_id"], workspace_id: row.workspace_id)
      return false unless job && Jobs.claim_material_available?(job, seat, at: at || WorkspaceLock.clock)

      Task.where(workspace_id: row.workspace_id, id: job.task_id, project_id: row.result.dig("input", "project_id")).exists?
    end

    def work_claim_deleted?(row)
      task_id = row.result&.dig("task", "id") || row.result&.dig("review", "task_id")
      task_id && Task.where(workspace_id: row.workspace_id, id: task_id).where.not(content_deleted_at: nil).exists?
    end

    def completed_claims(workspace_id)
      Command.where(workspace_id: workspace_id, caller_kind: "seat", outcome: "completed")
    end

    private_class_method :claim_material_available?, :work_claim_deleted?, :completed_claims
  end
end
