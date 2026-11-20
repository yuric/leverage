module Leverage
  # The jobs an orchestrator or a planner pulls (PRD L540, L545; jobs.json;
  # milestone 4 plan §2.1, RD-30 to RD-41, RC-49): the only writer of jobs
  # and the only emitter of job.*. Who may claim, in what order, and what
  # happens to a job that times out or is withdrawn. Each attempt of a
  # check is a job of its own (DB-31): a requeue writes job.requeued on the
  # old job and no job.queued for the new one.
  #
  # First version (milestone 4 plan §4, the hand-over table): every call
  # does nothing and answers nil. WP6 writes it.
  module Jobs
    module_function

    # Queues a job of kind (a registry job kind) about task, running target
    # (the RuleCheck of a check, the Task of a draft), for seat_role, with
    # input, the job's stored input (job.queued). Returns the Job.
    def queue(ctx, kind:, task:, target:, seat_role:, input:)
      nil
    end

    # The job seat would get from claim-next now: the one it holds, else
    # the oldest it may claim (RD-35, RD-36, RD-40), or nil. Reads only.
    def next_for(seat)
      nil
    end

    # seat claims job (job.claimed, with the credential and the model,
    # L872). Returns the Job.
    def claim(ctx, job, seat)
      nil
    end

    # The job's result was accepted (job.finished): result, tokens, spend.
    def finish(ctx, job, result:, tokens:, spend:)
      nil
    end

    # The job missed its due time: kind is :queue or :run
    # (Timers.job_due_at) (job.timed_out).
    def time_out(ctx, job, kind)
      nil
    end

    # The timed-out job's work is queued again as a new job
    # (job.requeued on the old one). Returns the new Job.
    def requeue(ctx, job)
      nil
    end

    # The job is withdrawn: its check was withdrawn, or the contract it
    # drafts was completed (job.withdrawn). A result sent afterwards is
    # refused (RD-41).
    def withdraw(ctx, job)
      nil
    end
  end
end
