module Leverage
  module Reads
    # The board (get_board; milestone 2 plan MA-20, MA-29, SC-11): every task
    # of the workspace with whether it is blocked, why, which credential it
    # waits for and the Needs you item it has open. One snapshot, so the
    # cards and as_of_seq are one moment of the log. The app puts the cards
    # in its six lanes and filters them; the read does not.
    module Board
      module_function

      # Raises ActiveRecord::RecordNotFound for an unknown workspace.
      def call(workspace_id)
        Snapshot.call(workspace_id) do |as_of_seq|
          tasks = Task.where(workspace_id: workspace_id).order(:created_at, :id).to_a
          task_ids = tasks.map(&:id)
          holds = Hold.where(workspace_id: workspace_id, task_id: task_ids, closed_at: nil).order(:opened_at, :id).group_by(&:task_id)
          items = InboxItem.where(workspace_id: workspace_id, about_kind: "task", about_id: task_ids, state: "open")
            .order(:opened_at, :id).to_a
          item_json = inbox_items(items).group_by { |item| item.fetch(:about_id) }
          credentials = Credential.where(id: holds.values.flatten.filter_map(&:credential_id)).index_by(&:id)

          { tasks: tasks.map { |task| card(task, holds.fetch(task.id, []), item_json[task.id]&.first, credentials) },
            as_of_seq: as_of_seq, reviewer_seat_exists: reviewer_seat?(workspace_id) }
        end
      end

      # Whether the workspace has a reviewer seat that is not removed: the
      # board and the task page say so when it has none (SC-11).
      def reviewer_seat?(workspace_id)
        Seat.where(workspace_id: workspace_id, role: "reviewer", removed_at: nil).exists?
      end

      # The Needs you items as the contract has them, each with the seq of its
      # inbox.opened event (the item's subject).
      def inbox_items(items)
        seqs = Event.where(type: "inbox.opened", subject_id: items.map(&:id)).pluck(:subject_id, :seq).to_h
        items.map { |item| Shapes.inbox_item(item, seqs.fetch(item.id)) }
      end

      def card(task, holds, item, credentials)
        waiting = holds.find(&:credential_id)
        { task: Shapes.task_summary(task), blocked: holds.any?, hold_reasons: holds.map(&:reason).uniq,
          waiting_for_credential_id: waiting&.credential_id,
          waiting_until: Shapes.time(waiting && credentials[waiting.credential_id]&.limited_until), inbox_item: item }
      end
    end
  end
end
