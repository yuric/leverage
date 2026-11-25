module V1
  module Agent
    # The agent's task calls. The briefing is a read.
    class TasksController < BaseController
      def create = run("create_task", "add_task")
      def claim_next = run("claim_next_task", "claim")
      def acknowledge_briefing = run("acknowledge_task_briefing", "acknowledge_briefing", ids: [ :id ])
      def heartbeat = run("heartbeat_task", "heartbeat", ids: [ :id ])
      def submit = run("submit_task", "submit", ids: [ :id ])
      def release = run("release_task", "release", ids: [ :id ])
      def access = run("request_access", "request_access", ids: [ :id ])
      def cost = run("report_cost", "report_cost", ids: [ :id ])

      # GET /v1/tasks/{id}/briefing: the briefing the holder reads, the work
      # reference, and the notes of the task's failed reviews (Q-9), which
      # are outside the hash like the work reference; a review a rule
      # failed carries the rule's name and the check's reason after the
      # reviewer's notes (Briefing.review_notes, RD-38). A task the seat does
      # not hold in Working or Finishing, or holds no longer, is 404: the seat may read
      # only what the Roles table gives it (L918), and a provisional
      # claimant, which holds a Ready task with no lease, gets no briefing
      # until its claim gate passes (L392, RE-5).
      def briefing
        task = Task.where(id: uuid_param!(:id), workspace_id: current_seat.workspace_id, holder_seat_id: current_seat.id,
          state: %w[working finishing]).where(Leverage::Reads::NextItem::LIVE).take || raise(NotFound, "No such task")
        render json: { briefing: Leverage::Briefing.build(task, current_seat), work_reference: task.work_reference,
                       review_notes: Leverage::Briefing.review_notes(task) }
      end
    end
  end
end
