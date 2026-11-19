module Leverage
  module Reads
    # The stable events tail (list_events; milestone 2 plan MA-20, IF-18):
    # committed events of the workspace with seq greater than after_seq, in
    # seq order, at most limit, and next_after_seq. A writer holds the
    # workspace lock from the moment it takes its first seq until it commits,
    # so events commit in seq order: a reader that passes next_after_seq back
    # misses nothing and never sees a gap fill in later.
    #
    # With wait it long-polls (LongPoll) until at least one event exists or
    # wait runs out; it holds no database connection between looks.
    module EventsTail
      module_function

      def call(workspace_id, after_seq: 0, limit: 100, wait: 0)
        events = LongPoll.wait(wait) do
          # Uncached: the request's query cache would answer every look after
          # the first with the first look's rows.
          page = ActiveRecord::Base.uncached do
            Event.where(workspace_id: workspace_id).where("seq > ?", after_seq).order(:seq).limit(limit).to_a
          end
          page if page.any?
        end || []
        { events: events.map { |event| Shapes.event(event) }, next_after_seq: events.last&.seq || after_seq }
      end
    end
  end
end
