module Leverage
  # What a claimed job hands its seat (milestone 4 plan §2.3, RD-30,
  # RD-37): the contract's input shape of the job's kind
  # (RuleCheckJobInput, ContractDraftJobInput) with its material: the
  # frozen rule version's instruction, the requested contract and each
  # quoted piece of task text, or the task's contract and its stored work
  # reference, minimum strength rank and budget cap. Built when the job is
  # claimed, never stored in an event. Reads only.
  #
  # First version (milestone 4 plan §4, the hand-over table): an empty
  # Hash. WP6 writes it.
  module JobInputs
    module_function

    # The input of job, a Hash with string keys.
    def for(job)
      {}
    end
  end
end
