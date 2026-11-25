# Runs a block with the step tracker reading a task's criteria as it did
# before task.created's criteria counted: from task.contract_changed alone.
# The rows a promoted Imaginarium idea got then are what
# Leverage::StepRepair repairs, so its tests store them this way. Each
# parallel test worker is a process of its own, so the swap is seen by
# this test alone.
module OldStepTracker
  def with_the_old_step_tracker
    steps = Leverage::Steps
    current = steps.method(:criteria_as_of)
    steps.define_singleton_method(:criteria_as_of) do |event|
      Event.where(workspace_id: event.workspace_id, task_id: event.task_id, type: "task.contract_changed")
        .where("seq <= ?", event.seq).order(:seq).pluck(:payload).each_with_object(Set.new) do |payload, ids|
          ids.merge(Array(payload["added_criterion_ids"]))
          ids.subtract(Array(payload["removed_criterion_ids"]))
        end
    end
    yield
  ensure
    steps.define_singleton_method(:criteria_as_of, current)
  end
end
