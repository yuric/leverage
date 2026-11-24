module Leverage
  module Reads
    # The inbox (list_inbox; milestone 3 plan HE-37, HE-40, HM-29): the
    # workspace's open Needs you items whatever their kind, each with the
    # seq of its inbox.opened event, oldest first. With after_seq only the
    # items whose inbox.opened has a greater seq, so the app announces each
    # item once; next_after_seq is the greatest seq it returned, or
    # after_seq when it returned none. An item that opened and was resolved
    # after after_seq is not here: the app learns of it from the events
    # tail (HM-29).
    #
    # A writer holds the workspace lock from the moment it takes its first
    # seq until it commits, so events commit in seq order and a reader that
    # passes next_after_seq back misses no item (the events tail's reason).
    #
    # With wait it long-polls (LongPoll) until at least one item is there
    # or wait runs out; it holds no database connection between looks.
    #
    # The open "Orchestrator offline" item says how many checks wait now,
    # not how many waited when it opened (milestone 4 plan RD-18): its
    # facts.waiting_checks is SystemHealth.waiting_checks, the count the
    # health line shows, read when the items are answered. The row keeps
    # the count it opened with; nothing is written.
    module Inbox
      # The item whose count is read again each time.
      COUNTED = "orchestrator_offline".freeze

      module_function

      def call(workspace_id, after_seq: 0, wait: 0)
        items = LongPoll.wait(wait) do
          # Uncached: the request's query cache would answer every look
          # after the first with the first look's rows.
          page = ActiveRecord::Base.uncached { open_after(workspace_id, after_seq) }
          page if page.any?
        end || []
        { items: shapes(workspace_id, items), next_after_seq: items.last&.last || after_seq }
      end

      # The items as the contract has them. Read the offline count and the
      # availability of Offer again from current rows.
      def shapes(workspace_id, items)
        counted = items.any? { |item, _| item.kind == COUNTED }
        count = (ActiveRecord::Base.uncached { SystemHealth.waiting_checks(workspace_id) } if counted)
        offerable = offerable_tasks(workspace_id, items)
        access = access_details(workspace_id, items)
        stops = action_stop_details(workspace_id, items)
        items.map do |item, seq|
          shape = Shapes.inbox_item(item, seq)
          detail = access[item.hold_id] || stops[item.hold_id]
          shape[:detail] = detail if detail
          if item.kind == COUNTED
            shape[:facts] = item.facts.merge("waiting_checks" => count)
          elsif item.kind == "unconfirmed_action" && !offerable.include?(item.about_id)
            shape[:choices] = item.choices - [ "offer_again" ]
          end
          shape
        end
      end

      def access_details(workspace_id, items)
        ids = items.filter_map { |item, _seq| item.hold_id if item.kind == "access_request" }
        Hold.where(workspace_id: workspace_id, id: ids, reason: "access").pluck(:id, :detail).to_h
      end

      def action_stop_details(workspace_id, items)
        ids = items.filter_map { |item, _seq| item.hold_id if item.kind == "stopped_action" }
        Hold.where(workspace_id: workspace_id, id: ids, reason: "action_stopped", closed_at: nil)
          .joins("INNER JOIN actions ON actions.id = holds.action_id AND actions.workspace_id = holds.workspace_id")
          .joins("INNER JOIN jobs ON jobs.id = actions.approval_job_id AND jobs.workspace_id = actions.workspace_id")
          .where(jobs: { kind: "approval", state: "finished" }).pluck("holds.id", "jobs.result")
          .filter_map { |id, result| [ id, result["reason"] ] if result&.fetch("decision", nil) == "stop" }.to_h
      end

      def offerable_tasks(workspace_id, items)
        ids = items.filter_map { |item, _seq| item.about_id if item.kind == "unconfirmed_action" }
        builders = Seat.where(workspace_id: workspace_id, role: Roles.roles_acting_as("builder"), enabled: true, removed_at: nil).select(:id)
        Task.where(workspace_id: workspace_id, id: ids, builder_seat_id: builders).pluck(:id).to_set
      end

      # [item, opened_seq] pairs in seq order.
      def open_after(workspace_id, after_seq)
        rows = InboxItem.joins("INNER JOIN events ON events.subject_id = inbox_items.id AND events.type = 'inbox.opened'")
          .where(workspace_id: workspace_id, state: "open").where("events.workspace_id = inbox_items.workspace_id")
          .where("events.seq > ?", after_seq).order("events.seq").select("inbox_items.*", "events.seq AS opened_seq").to_a
        rows.map { |item| [ item, item.opened_seq ] }
      end
    end
  end
end
