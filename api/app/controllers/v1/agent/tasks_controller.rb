module V1
  module Agent
    # The task calls: claim, briefing, acknowledge, heartbeat, submit and
    # release (milestone 2 plan §2.1). The briefing is a read.
    class TasksController < BaseController
      def claim_next = run("claim_next_task", "claim")
      def acknowledge_briefing = run("acknowledge_task_briefing", "acknowledge_briefing", ids: [ :id ])
      def heartbeat = run("heartbeat_task", "heartbeat", ids: [ :id ])
      def submit = run("submit_task", "submit", ids: [ :id ])
      def release = run("release_task", "release", ids: [ :id ])

      # GET /v1/tasks/{id}/briefing: the briefing the holder reads, the work
      # reference, and the notes of the task's failed reviews (Q-9), which
      # are outside the hash like the work reference. A task the seat does
      # not hold, or holds no longer, is 404: the seat may read only what
      # the Roles table gives it (L918).
      def briefing
        task = Task.where(id: uuid_param!(:id), workspace_id: current_seat.workspace_id, holder_seat_id: current_seat.id)
          .where(Leverage::Reads::NextItem::LIVE).take || raise(NotFound, "No such task")
        render json: { briefing: Leverage::Briefing.build(task, current_seat), work_reference: task.work_reference,
                       review_notes: review_notes(task) }
      end

      private

      def review_notes(task)
        Review.where(task_id: task.id, verdict: "failed").order(:round)
          .map { |review| { review_id: review.id, round: review.round, notes: review.notes } }
      end
    end
  end
end
