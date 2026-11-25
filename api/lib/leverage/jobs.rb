module Leverage
  # The jobs an orchestrator or a planner pulls (PRD L540, L545, L872;
  # jobs.json; milestone 4 plan §2.1, RD-30 to RD-41, RC-49, IF-13): the
  # only writer of jobs and the only emitter of job.*. Who may claim, in
  # what order, and what happens to a job that is claimed, finishes, times
  # out, is queued again or is withdrawn. Each attempt of a check is a job
  # of its own (DB-31, RD-44): a requeue writes job.requeued on the old job
  # and no job.queued for the new one.
  #
  # Who may claim (L545, RD-35, RD-36, HD-4): an enabled seat, not paused
  # and not removed, of the role that claims the job's kind (IF-13: the
  # orchestrator checks and questions, the planner contract drafts); for a seat the
  # app runs, its run on its first available candidate (as Eligibility asks
  # of a builder or a reviewer), so the claim records the account that does
  # the work. A seat holds one job at a time and gets that one again (RD-40);
  # otherwise the oldest queued job, by queue time and then id (action batches use enqueue order), of a task
  # it never claimed as a builder (RC-49, from task.claimed), and never the
  # task.before_ready check of a task whose contract it drafted or that it
  # added (GA-5, UX-11). A job whose due time has passed is never given
  # out: its timer ends it (L399).
  #
  # The events carry the command's caller, key and time unless the caller
  # names them: a writer that runs inside a timer passes its effective time,
  # the app as actor and no key (EVENT_FIELDS).
  module Jobs
    # The event fields a caller may name for every event a writer here
    # writes.
    EVENT_FIELDS = %i[effective_at actor_kind actor_id command_id cause_id].freeze

    # Action jobs queued at the same effective time follow their enqueue
    # events. A retried action check names its new job on check.queued.
    # Other jobs keep the existing queued time and ID order (RD-35).
    ACTION_QUEUE_ORDER = <<~SQL.squish.freeze
      CASE WHEN jobs.kind IN ('rule_check', 'approval') AND EXISTS (
        SELECT 1 FROM rule_checks
        WHERE rule_checks.workspace_id = jobs.workspace_id AND rule_checks.id = jobs.target_id
          AND rule_checks.hook = 'action.requested'
      ) THEN (
        SELECT MIN(events.seq) FROM events
        WHERE events.workspace_id = jobs.workspace_id AND events.task_id = jobs.task_id AND (
          (events.type = 'job.queued' AND events.subject_id = jobs.id) OR
          (events.type = 'check.queued' AND events.subject_id = jobs.target_id AND events.payload->>'job_id' = jobs.id::text)
        )
      ) END ASC NULLS FIRST
    SQL

    module_function

    # Queues a job of kind (a registry job kind) about task, running target
    # (the RuleCheck of a check, the Task of a draft), for seat_role, with
    # input, the job's stored input, and writes job.queued. id: lets a
    # caller name the job before it is queued (check.queued names its job
    # and comes first, trace 16); attempt_number: is the attempt a rule
    # check's job runs (1 for any other job).
    #
    # Returns the Job.
    def queue(ctx, kind:, task:, target:, seat_role:, input:, id: nil, attempt_number: 1, **as)
      fields = event_fields(ctx, as)
      job = Job.create!(id: id || SecureRandom.uuid, workspace_id: ctx.workspace.id, kind: kind, task_id: task&.id,
        project_id: task&.project_id, target_kind: EventLog.kind_of(target), target_id: target.id, seat_role: seat_role,
        state: "queued", queued_at: fields[:effective_at], input: JobInputs.store(input, seat_role, kind: kind), attempt_number: attempt_number)
      emit(ctx, "job.queued", job, task, fields, payload: { kind: kind })
      job
    end

    # The job seat would get from claim-next at at: the one it holds, else
    # the oldest it may claim, or nil. Reads only. Work on tasks gates the
    # new claim only: the job the seat holds goes on (UX-11a), so a run
    # moved to another credential still gets it again (RD-40).
    def next_for(seat, at: Time.current, additional: [])
      return nil unless active?(seat, new_claim: false)

      job = held(seat, at)
      if job
        return unless claim_material_available?(job, seat, at: at)

        return (job if seat.credential_id.nil? || Candidates.first_available(seat, nil, at))
      end
      return nil unless Permissions.works?(seat) && ready_to_claim?(seat, at)

      queued = claimable(seat, at)
      proposed = additional.select { |item| claimable_proposal?(item, seat, at) }.min_by(&:queued_at)
      proposed && (queued.nil? || proposed.queued_at < queued.queued_at) ? proposed : queued
    end

    # Recovery checks eligibility for this attempt independently of queue order.
    def may_claim_proposal?(job, seat, at:)
      active?(seat) && ready_to_claim?(seat, at) && claimable_proposal?(job, seat, at)
    end

    def ready_to_claim?(seat, at)
      placed?(seat, at) && (seat.role != "general" || Eligibility.idle_for_claim?(seat, at: at))
    end

    # A stored claim can show its material only to the seat that can still hold it.
    def claim_material_available?(job, seat, at:)
      return false unless active?(seat, new_claim: false) && job.workspace_id == seat.workspace_id && job.claimed_by_seat_id == seat.id &&
        job.state == "claimed" && role_matches?(job, seat) && !due?(job, :run, at)

      task = task_of(job)
      !task&.content_deleted_at && (job.kind != "question" || (task && !%w[done cancelled].include?(task.state)))
    end

    # A seat can change role while it holds a job. The old job still occupies
    # the seat until it ends, but only the job's role can receive or finish it.
    def role_matches?(job, seat)
      Roles.acts_as?(seat.role, job.seat_role) && kinds_for(seat.role).include?(job.kind)
    end

    # The job the seat holds now: claimed by it and its run time not over,
    # or nil.
    def held(seat, at = Time.current)
      Job.where(workspace_id: seat.workspace_id, claimed_by_seat_id: seat.id, state: "claimed")
        .where.not(kind: "question", task_id: ended_tasks(seat.workspace_id))
        .order(:claimed_at, :id).find { |job| !due?(job, :run, at) }
    end

    # seat claims job: the job records the seat, the time and the
    # credential its run is on, and job.claimed carries that credential and
    # the model a run on it uses (L872, HE-5). A seat that connects on its
    # own has no credential; its model is its own.
    #
    # Returns the Job.
    def claim(ctx, job, seat)
      credential = seat.credential_id && Candidates.first_available(seat, nil, ctx.at)
      job.update!(state: "claimed", claimed_by_seat_id: seat.id, claimed_at: ctx.at, credential_id: credential&.id)
      emit(ctx, "job.claimed", job, task_of(job), event_fields(ctx, {}),
        payload: { credential_id: credential&.id, model: Candidates.model_for(seat, credential) })
      job
    end

    # The model a run of the job's seat on the job's credential uses, as
    # job.claimed and credential.switched record it.
    def model_of(job, seat)
      credential = job.credential_id && Credential.find_by(id: job.credential_id, workspace_id: job.workspace_id)
      Candidates.model_for(seat, credential)
    end

    # The job's result was accepted: the result, the tokens and the spend
    # are kept on the row (DB-31), and job.finished is written.
    def finish(ctx, job, result:, tokens:, spend:)
      fields = event_fields(ctx, {})
      job.update!(state: "finished", finished_at: fields[:effective_at], result: result, tokens: tokens, spend: spend)
      emit(ctx, "job.finished", job, task_of(job), fields)
    end

    # The job missed its due time: kind is :queue or :run
    # (Timers.job_due_at). The job ends at the time the timer gives, and
    # job.timed_out is written.
    def time_out(ctx, job, kind, **as)
      raise ArgumentError, "kind is :queue or :run, not #{kind.inspect}" unless %i[queue run].include?(kind)

      fields = event_fields(ctx, as)
      job.update!(state: "timed_out", finished_at: fields[:effective_at])
      emit(ctx, "job.timed_out", job, task_of(job), fields)
    end

    # The timed-out job's work is queued again as a new job, the next
    # attempt, with the same kind, task, target, role and input:
    # job.requeued on the old one, and no job.queued for the new (DB-31).
    #
    # Returns the new Job.
    def requeue(ctx, job, **as)
      fields = event_fields(ctx, as)
      emit(ctx, "job.requeued", job, task_of(job), fields)
      Job.create!(workspace_id: job.workspace_id, kind: job.kind, task_id: job.task_id, project_id: job.project_id,
        target_kind: job.target_kind, target_id: job.target_id, seat_role: job.seat_role, state: "queued",
        queued_at: fields[:effective_at], input: job.input, attempt_number: job.attempt_number + 1)
    end

    # The job is withdrawn: its check was withdrawn, or the contract it
    # drafts was completed (job.withdrawn). A result sent afterwards is
    # refused (RD-41).
    def withdraw(ctx, job, **as)
      fields = event_fields(ctx, as)
      job.update!(state: "withdrawn", finished_at: fields[:effective_at])
      emit(ctx, "job.withdrawn", job, task_of(job), fields)
    end

    # Whether the job's due time of kind (:queue or :run) has passed at at.
    def due?(job, kind, at)
      due = Timers.job_due_at(job, kind)
      !due.nil? && due <= at
    end

    # --- who may claim, and what --------------------------------------------

    # L545 for a job's seat: enabled, not paused, not removed, of a role
    # that claims a job kind.
    def active?(seat, new_claim: true)
      seat&.enabled && !seat.paused && seat.removed_at.nil? && kinds_for(seat.role).any? &&
        (!new_claim || Permissions.works?(seat))
    end

    # HD-4: a seat that connects on its own always; a seat the app runs
    # when its run is on its first candidate available at at. A seat that
    # holds a job goes on with it while any candidate is available (RD-40:
    # with none, it stops claiming jobs and the job runs into its timeout).
    def placed?(seat, at)
      return true unless seat.credential_id

      first = Candidates.first_available(seat, nil, at)
      !first.nil? && SeatRuns.run_credential_id(seat) == first.id
    end

    # The oldest queued job of the seat's kinds whose queue time has not
    # run out, of a task the seat never claimed as a builder and that is
    # neither cancelled nor stripped of content. A Done task's jobs
    # still run while it has content (RC-16), except question jobs.
    # An action batch can queue
    # more than one job at the same effective time.
    def claimable(seat, at)
      queued = Job.where(workspace_id: seat.workspace_id, state: "queued", kind: kinds_for(seat.role),
        seat_role: definitions_for(seat.role).map { |job| job.fetch("claimer_role") }.uniq)
      queued.where.not(task_id: built_by(seat)).where.not(task_id: unavailable_tasks(seat.workspace_id))
        .or(queued.where(task_id: nil)).where.not(kind: "question", task_id: ended_tasks(seat.workspace_id))
        .order(:queued_at, Arel.sql(ACTION_QUEUE_ORDER), :id).find do |job|
          !due?(job, :queue, at) && !own_draft_check?(job, seat)
        end
    end

    def ended_tasks(workspace_id)
      Task.where(workspace_id: workspace_id, state: %w[done cancelled]).select(:id)
    end

    def unavailable_tasks(workspace_id)
      tasks = Task.where(workspace_id: workspace_id)
      tasks.where(state: "cancelled").or(tasks.where.not(content_deleted_at: nil)).select(:id)
    end

    # Presence and question routing can ask about a job before it enters
    # the queue. Existing jobs win a tie with these proposed rows.
    def claimable_proposal?(job, seat, at)
      return false unless job.workspace_id == seat.workspace_id && job.state == "queued" && role_matches?(job, seat)
      return false if due?(job, :queue, at) || own_draft_check?(job, seat)
      return true unless job.task_id

      !built_by(seat).exists?(task_id: job.task_id) && !unavailable_tasks(seat.workspace_id).exists?(id: job.task_id) &&
        (job.kind != "question" || !ended_tasks(seat.workspace_id).exists?(id: job.task_id))
    end

    # PRD Who may check, GA-5: a seat does not check at task.before_ready
    # a task whose contract it wrote, as the planner of a finished draft or
    # as the seat that added the task (its task.created actor, UX-11). Both
    # read what the seat did, not the role it has now.
    def own_draft_check?(job, seat)
      return false unless job.kind == "rule_check" && job.task_id
      return false unless RuleCheck.exists?(workspace_id: job.workspace_id, id: job.target_id, hook: "task.before_ready")

      Job.where(workspace_id: job.workspace_id, task_id: job.task_id, kind: "contract_draft",
        claimed_by_seat_id: seat.id, state: "finished").exists? ||
        Event.where(workspace_id: job.workspace_id, task_id: job.task_id, type: "task.created",
          actor_kind: "seat", actor_id: seat.id).exists?
    end

    # The job kinds a role claims (IF-13, jobs.json claimer_role).
    def kinds_for(role)
      definitions_for(role).map { |job| job.fetch("kind") }
    end

    def definitions_for(role)
      Contract.jobs.fetch("jobs").select { |job| Roles.acts_as?(role, job.fetch("claimer_role")) }
    end

    # The tasks the seat ever claimed as a builder (RC-49, RD-36).
    def built_by(seat)
      Event.where(workspace_id: seat.workspace_id, type: Leases::BUILDER_GRANT)
        .where("payload ->> 'seat_id' = ?", seat.id).where.not(task_id: nil).select(:task_id)
    end

    def task_of(job) = job.task_id && Task.find_by(id: job.task_id, workspace_id: job.workspace_id)

    # The command's own time, caller and key, with what the caller names.
    def event_fields(ctx, as)
      unknown = as.keys - EVENT_FIELDS
      raise ArgumentError, "unknown event fields #{unknown.inspect}" unless unknown.empty?

      { effective_at: ctx.effective_at }.merge(as)
    end

    def emit(ctx, type, job, task, fields, payload: {})
      fields = fields.merge(task: task) if task
      ctx.emit(type, subject: job, payload: payload, **fields)
    end

    private_class_method :active?, :placed?, :ready_to_claim?, :claimable, :ended_tasks, :unavailable_tasks, :claimable_proposal?, :own_draft_check?,
      :kinds_for, :definitions_for, :built_by, :task_of, :event_fields, :emit
  end
end
