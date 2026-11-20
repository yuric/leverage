module Leverage
  # Compares a task's criteria with an edited contract (PRD Contract edits
  # and cancel, L205: "Criteria that are unchanged and already passed stay
  # passed"; milestone 3 plan HE-25 (i)). A criterion keeps its identity by
  # position and kind:
  #
  #   same position, kind and text   kept, with its state and evidence
  #   same position and kind, other text   reset to open, same id
  #   a position that is new         added, in state open
  #   a position that is gone        removed (removed_at set)
  #   a changed kind                 the old one removed, a new one added
  #
  # compare reads; write applies the comparison to the rows. Neither writes
  # an event: the caller writes task.contract_changed with write's ids.
  module ContractDiff
    # kept:    the Criteria kept as they are.
    # reset:   [Criterion, wanted] pairs whose text changes.
    # added:   [position, wanted] pairs, in position order.
    # removed: the Criteria removed, in position order.
    Diff = Data.define(:kept, :reset, :added, :removed)

    # The ids task.contract_changed lists.
    Written = Data.define(:added_ids, :reset_ids, :removed_ids)

    module_function

    # Compares current criteria (not removed) with the wanted list, whose
    # entries are { "text", "kind" } in order: position n is entry n - 1.
    #
    # Returns a Diff.
    def compare(current, wanted)
      by_position = current.index_by(&:position)
      diff = { kept: [], reset: [], added: [], removed: [] }
      wanted.each_with_index do |entry, index|
        position = index + 1
        criterion = by_position.delete(position)
        if criterion.nil?
          diff[:added] << [ position, entry ]
        elsif criterion.kind != entry.fetch("kind")
          diff[:removed] << criterion
          diff[:added] << [ position, entry ]
        elsif criterion.text == entry.fetch("text")
          diff[:kept] << criterion
        else
          diff[:reset] << [ criterion, entry ]
        end
      end
      diff[:removed] = (diff[:removed] + by_position.values).sort_by(&:position)
      Diff.new(**diff)
    end

    # Compares the task's current criteria with wanted and writes the
    # result: removals first (so a position freed by a changed kind can be
    # taken again, criteria are unique by task and position while not
    # removed), then resets, then additions.
    #
    # at - the command's time, for removed_at.
    #
    # Returns the Written ids.
    def write(task, wanted, at:)
      diff = compare(Criterion.where(task_id: task.id, removed_at: nil).order(:position).to_a, wanted)
      diff.removed.each { |criterion| criterion.update!(removed_at: at) }
      diff.reset.each do |criterion, entry|
        criterion.update!(text: entry.fetch("text"), state: "open", passed_at: nil, passed_by_seat_id: nil)
      end
      added = diff.added.map do |position, entry|
        Criterion.create!(workspace_id: task.workspace_id, task_id: task.id, position: position,
          kind: entry.fetch("kind"), text: entry.fetch("text"))
      end
      Written.new(added_ids: added.map(&:id), reset_ids: diff.reset.map { |criterion, _| criterion.id },
        removed_ids: diff.removed.map(&:id))
    end
  end
end
