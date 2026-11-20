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

      # The items as the contract has them, the count of an open
      # Orchestrator offline item read now.
      def shapes(workspace_id, items)
        counted = items.any? { |item, _| item.kind == COUNTED }
        count = (ActiveRecord::Base.uncached { SystemHealth.waiting_checks(workspace_id) } if counted)
        items.map do |item, seq|
          shape = Shapes.inbox_item(item, seq)
          item.kind == COUNTED ? shape.merge(facts: item.facts.merge("waiting_checks" => count)) : shape
        end
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
