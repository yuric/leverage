module Leverage
  module Transitions
    # What the four job timers share (PRD L398, L399; timers.json;
    # state_machine.json; milestone 4 plan WP7, DB-31): a job not claimed
    # within its queue timeout, or not finished within its run timeout,
    # misses. A first miss times the job out and queues its work once more
    # as a new job (and, for a rule check, a new attempt); a second miss
    # (Timers.second_miss?) times it out for good: a check's result is then
    # error, and an error on a blocking rule leaves its transition pending
    # under check_error (CheckReentry.after with the trigger
    # check_timed_out, rule 9 of the plan's §2.1), while a draft just ends
    # and its task stays in Backlog.
    #
    # Each miss is written inside Timers.as_timer: by the app, with no key,
    # effective at the job's due time (never before the task's latest
    # event, Timers.effective_at), by the writers that own the rows (Jobs,
    # RuleChecks, PendingTransitions).
    #
    # It runs in two ways, through the same code (L118):
    #
    #   inside another command  Timers.apply_due makes it with targets:,
    #                           the one job that is due;
    #   as its own command      the sweep's, by the app: params job_id
    #                           names one job, or with none it takes the
    #                           workspace's due jobs, oldest due first, at
    #                           most params limit (default BATCH).
    #
    # Result: timed_out_job_ids, the jobs it timed out.
    class JobTimer < Entry
      BATCH = 100
      CHECK_TIMED_OUT = :check_timed_out

      def initialize(command = self.class.command, targets: nil)
        super(command)
        @jobs = targets
        @named = false
      end

      def load(ctx)
        return if @jobs

        params = ctx.request.params
        if params.key?("job_id")
          @named = true
          @jobs = [ Job.find_by(id: params["job_id"], workspace_id: ctx.workspace.id) || raise(NotFound, "no such job") ]
        else
          @jobs = Timers.due_jobs(ctx.workspace.id, ctx.at, command, limit: Integer(params.fetch("limit", BATCH)))
        end
      end

      # A named job must be of the timer's kind and in the state it reads.
      def refusals(_ctx)
        return [] if !@named || Timers.job_timer_for(@jobs.sole) == command

        [ Refusal.new(code: Contract.state_machine.fetch("unlisted_pair_refusal")) ]
      end

      def perform(ctx)
        missed = @jobs.map { |job| Job.find(job.id) }.select { |job| Timers.job_timer_due?(job, command, ctx.at) }
        missed.each do |job|
          due = Timers.job_timer_due_at(job, command)
          task = job.task_id && Task.find_by(id: job.task_id, workspace_id: job.workspace_id)
          Timers.as_timer(ctx, command, task ? Timers.effective_at(task, due) : due) { |timer_ctx| miss(timer_ctx, job) }
        end
        @result = { "timed_out_job_ids" => missed.map(&:id) }
      end

      # GA-17 makes a claimed job miss its run time at the command's clock.
      def miss_now(ctx, job)
        Timers.as_timer(ctx, command, ctx.at) { |timer_ctx| miss(timer_ctx, job) }
      end

      private

      def due_kind = Timers::JOB_TIMERS.fetch(command).fetch(:due)

      def miss(ctx, job)
        second = Timers.second_miss?(job)
        Timers.check_job?(job) ? check_miss(ctx, job, second) : draft_miss(ctx, job, second)
      end

      # The rows of state_machine.json: first_miss job.timed_out,
      # job.requeued, check.queued; second_miss job.timed_out,
      # check.finished, and the hold (and item) re-entry opens.
      def check_miss(ctx, job, second)
        check = RuleCheck.find(RuleCheckAttempt.find_by!(job_id: job.id).rule_check_id)
        Jobs.time_out(ctx, job, due_kind)
        return RuleChecks.new_attempt(ctx, check, job: Jobs.requeue(ctx, job)) unless second

        finished = RuleChecks.error(ctx, check)
        if job.kind == "approval"
          action = Action.find_by!(id: check.subject_id, task_id: check.task_id, workspace_id: ctx.workspace.id)
          Finishing.open_owner_approval(ctx, action, check: check, cause: finished)
        else
          CheckReentry.after(ctx, check, Gating::Trigger.new(kind: CHECK_TIMED_OUT, rule_check_id: check.id))
        end
      end

      # first_miss job.timed_out, job.requeued; second_miss job.timed_out.
      def draft_miss(ctx, job, second)
        Jobs.time_out(ctx, job, due_kind)
        Jobs.requeue(ctx, job) unless second
      end
    end
  end
end
