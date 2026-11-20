module Leverage
  module Reads
    # One task's page (get_task; milestone 2 plan MA-20, MA-29, IN-35): the
    # contract, the criteria with their evidence, the actions and questions,
    # every hold, the reviews, the open Needs you items, the task's events in
    # seq order for its log, and the names that log needs. One snapshot, so
    # the page and as_of_seq are one moment of the log.
    module TaskPage
      UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

      module_function

      # The page, or nil when the workspace has no such task. Raises
      # ActiveRecord::RecordNotFound for an unknown workspace.
      def call(workspace_id, task_id)
        Snapshot.call(workspace_id) do |as_of_seq|
          task = Task.find_by(workspace_id: workspace_id, id: task_id)
          next nil unless task

          page(workspace_id, task, as_of_seq)
        end
      end

      def page(workspace_id, task, as_of_seq)
        criteria = Criterion.where(task_id: task.id, removed_at: nil).order(:position, :id).to_a
        evidence = Evidence.where(criterion_id: criteria.map(&:id)).order(:created_at, :id).group_by(&:criterion_id)
        reviews = Review.where(task_id: task.id).order(:round, :created_at, :id).to_a
        events = Event.where(workspace_id: workspace_id, task_id: task.id).order(:seq).to_a
        items = InboxItem.where(workspace_id: workspace_id, about_kind: "task", about_id: task.id, state: "open")
          .order(:opened_at, :id).to_a

        { task: Shapes.task_summary(task),
          criteria: criteria.map { |criterion| Shapes.criterion(criterion, evidence.fetch(criterion.id, [])) },
          actions: Action.where(task_id: task.id).order(:position, :id).map { |action| Shapes.action(action) },
          questions: Question.where(task_id: task.id).order(:asked_at, :id).map { |question| Shapes.question(question) },
          holds: Hold.where(task_id: task.id).order(:opened_at, :id).map { |hold| Shapes.hold(hold) },
          reviews: reviews.map { |review| Shapes.review(review) },
          inbox_items: Board.inbox_items(items),
          events: events.map { |event| Shapes.event(event) },
          names: names(workspace_id, task, reviews, events),
          reviewer_seat_exists: Board.reviewer_seat?(workspace_id),
          as_of_seq: as_of_seq }
      end

      # The seats and credentials the task's events, the task row and its
      # reviews carry, each with the name its log shows (IN-35). A removed
      # seat keeps its name.
      def names(workspace_id, task, reviews, events)
        seat_ids = [ task.holder_seat_id, task.builder_seat_id, *reviews.map(&:reviewer_seat_id) ]
        credential_ids = [ task.credential_id, *reviews.map(&:credential_id) ]
        events.each do |event|
          seat_ids << event.actor_id if event.actor_kind == "seat"
          seat_ids << event.subject_id if event.subject_kind == "seat"
          credential_ids << event.subject_id if event.subject_kind == "credential"
          collect_ids(event.payload, seat_ids, credential_ids)
        end

        seats = Seat.where(workspace_id: workspace_id, id: valid(seat_ids)).map { |seat| log_name("seat", seat) }
        credentials = Credential.where(workspace_id: workspace_id, id: valid(credential_ids)).map { |row| log_name("credential", row) }
        (seats + credentials).sort_by { |name| [ name.fetch(:kind), name.fetch(:name), name.fetch(:id) ] }
      end

      def log_name(kind, row) = { kind: kind, id: row.id, name: row.name }

      # Walks a payload for the ids it names: a key ending in seat_id is a
      # seat, one ending in credential_id a credential.
      def collect_ids(value, seat_ids, credential_ids)
        case value
        when Hash
          value.each do |key, inner|
            seat_ids << inner if key.to_s.end_with?("seat_id") && inner.is_a?(String)
            credential_ids << inner if key.to_s.end_with?("credential_id") && inner.is_a?(String)
            collect_ids(inner, seat_ids, credential_ids)
          end
        when Array
          value.each { |inner| collect_ids(inner, seat_ids, credential_ids) }
        end
      end

      def valid(ids) = ids.compact.uniq.grep(UUID)
    end
  end
end
