module Leverage
  # A seat's candidates (PRD L650-L703; milestone 3 plan §2.1 rules 1 to 4
  # and 8, HE-3, HE-4, HE-5, HE-35): the one reading of L672 every engine
  # package uses. It reads and writes nothing else; the commands call it
  # under the workspace lock and GET /v1/next outside one.
  #
  # A piece of work ("work" below) is a Task, a Review or nil. nil asks
  # only rule 2: the account a seat's run belongs on when it holds nothing.
  module Candidates
    module_function

    # Rule 1: every added login whose position is at or after the seat's
    # own credential's, in position order, its own first. A seat with no
    # credential (one that connects on its own) has none. API tokens keep
    # their place in the order but are no candidate (L672).
    #
    # Returns an Array of Credentials.
    def for(seat)
      return [] unless seat&.credential_id

      own = Credential.find_by(id: seat.credential_id, workspace_id: seat.workspace_id)
      return [] unless own

      Credential.added.where(workspace_id: seat.workspace_id, kind: "login").where(position: own.position..)
        .order(:position, :id).to_a
    end

    # Rule 2: active and not limited at time at (HE-3). Nothing is written
    # when a reset time passes.
    def available?(credential, at)
      credential.state == "active" && !credential.limited?(at)
    end

    # The first candidate available at at that rule 3 keeps for work.
    # Returns the Credential, or nil.
    def first_available(seat, work, at)
      self.for(seat).find { |credential| usable?(seat, credential, work, at) }
    end

    # Rule 4: after stopped, the first available candidate below it (rule
    # 3 applies); if there is none, the seat's own credential when that is
    # available; otherwise none. A candidate between the seat's own and
    # stopped is never taken here (L680, HE-4), and stopped never is.
    #
    # Returns the Credential, or nil.
    def next_after(seat, work, stopped, at)
      candidates = self.for(seat).reject { |credential| credential.id == stopped.id }
      below = candidates.find { |credential| credential.position > stopped.position && usable?(seat, credential, work, at) }
      return below if below

      own = candidates.find { |credential| credential.id == seat.credential_id }
      own if own && usable?(seat, own, work, at)
    end

    # The signed-in candidate rule 3 keeps for work whose limit ends first
    # after at: limited, with a reset time (HE-13: the hold names it). A
    # signed-out candidate's reset time is not one (rule 8).
    #
    # Returns the Credential, or nil.
    def earliest_reset(seat, work, at)
      self.for(seat)
        .select { |credential| credential.state == "active" && credential.limited?(at) && credential.limited_until }
        .select { |credential| passes_for_work?(seat, credential, work) }
        .min_by { |credential| [ credential.limited_until, credential.position ] }
    end

    # Rule 8 (HE-23): the due time of the credential hold of work's task.
    # The task's last effective time when a candidate rule 3 keeps is
    # available at at; otherwise the earliest reset among the signed-in
    # candidates rule 3 keeps, never before the task's last effective
    # time; nil when there is none (the hold then has an item).
    #
    # Returns a Time, or nil.
    def due_at(seat, work, at)
      return nil unless work

      last = last_effective_at(task_of(work)) || at
      return last if first_available(seat, work, at)

      reset = earliest_reset(seat, work, at)
      reset && [ reset.limited_until, last ].max
    end

    # Whether any of the seat's candidates that rule 3 keeps for work is
    # signed out (rule 6: the hold's reason is then credential_signed_out).
    # With no work, every candidate counts.
    def any_signed_out?(seat, work = nil)
      !signed_out_for(seat, work).nil?
    end

    # Whether credential is one of the seat's candidates and rule 3 keeps
    # it for work.
    def kept_for?(seat, credential, work)
      self.for(seat).any? { |candidate| candidate.id == credential.id } && passes_for_work?(seat, credential, work)
    end

    # The first signed-in candidate rule 3 keeps for work that is limited
    # at at with no reset time: what a credential hold with no due time
    # waits for when no candidate is signed out (HE-13).
    #
    # Returns the Credential, or nil.
    def limited_with_no_reset_for(seat, work, at)
      self.for(seat).find do |credential|
        credential.state == "active" && credential.limited?(at) && credential.limited_until.nil? &&
          passes_for_work?(seat, credential, work)
      end
    end

    # The first of the seat's candidates, in order, that is signed out and
    # that rule 3 keeps for work: the login a credential_signed_out hold
    # names (HE-12). A login the work passes over is never one: signing it
    # in would not let the work go on (PRD L670).
    #
    # Returns the Credential, or nil.
    def signed_out_for(seat, work)
      self.for(seat).find { |credential| credential.state == "signed_out" && passes_for_work?(seat, credential, work) }
    end

    # HE-5: the model a run of the seat on credential uses. Within the
    # seat's provider group the seat's own; in another group the
    # credential's. Empty is nil: the tool's own default.
    def model_for(seat, credential)
      (same_group?(seat, credential) ? seat.model : credential.model).presence
    end

    # HE-5: the effort, by the same rule as the model.
    def effort_for(seat, credential)
      (same_group?(seat, credential) ? seat.effort : credential.effort).presence
    end

    # Whether credential is of the seat's provider group (L588: "the same
    # provider"). A seat with no credential is of its own provider's.
    def same_group?(seat, credential)
      credential.nil? || provider_group(credential.provider) == provider_group(seat.provider)
    end

    # HE-35: the cause of a wait_ready step that opens now for task:
    # "credential_limit" when at least one builder seat would be eligible
    # for the task if accounts were left out, none of those seats has an
    # available candidate for it, and none of their candidates that rule 3
    # keeps for it is signed out; else nil. A seat that connects on its own
    # always counts as having one. Callers ask after their own rows are
    # written, so a seat that has just let the task go holds nothing.
    def wait_cause(task, at)
      seats = Seat.where(workspace_id: task.workspace_id, role: Roles.roles_acting_as("builder"), enabled: true, paused: false, removed_at: nil)
        .order(:created_at, :id).select { |seat| eligible_but_for_accounts?(seat, task, at) }
      return nil if seats.empty?
      return nil if seats.any? { |seat| seat.credential_id.nil? || first_available(seat, task, at) }
      return nil if seats.any? { |seat| any_signed_out?(seat, task) }

      "credential_limit"
    end

    # Rule 2 and rule 3 together.
    def usable?(seat, credential, work, at)
      available?(credential, at) && passes_for_work?(seat, credential, work)
    end

    # Rule 3: for one piece of work, a credential of another provider group
    # whose strength rank is below the task's minimum is passed over (a
    # credential with no rank has none); for a review, so is one the
    # provider rule refuses (Gating.provider_allowed?, HE-41).
    def passes_for_work?(seat, credential, work)
      return true unless work

      task = task_of(work)
      minimum = task.minimum_strength_rank
      rank = credential.strength_rank
      return false if minimum && rank && rank < minimum && !same_group?(seat, credential)
      return true unless work.is_a?(Review)

      return false if seat.role == "general" && credential.provider == "gemini"

      Gating.provider_allowed?(task_id: task.id, provider: credential.provider)
    end

    def task_of(work) = work.is_a?(Review) ? Task.find(work.task_id) : work

    def last_effective_at(task)
      Event.where(workspace_id: task.workspace_id, task_id: task.id).maximum(:effective_at)
    end

    # What a claim asks of a builder besides its accounts (Eligibility,
    # L545): enabled, not paused, not removed (the query above), holding
    # nothing with no approved action waiting, strong enough for the task,
    # the task's project running, and not filtered out of the claim by gating.
    def eligible_but_for_accounts?(seat, task, at)
      return false unless Eligibility.idle_for_claim?(seat, at: at)
      return false unless Eligibility.claim_standing?(seat, task)
      return false if task.project_id && Project.where(id: task.project_id, paused: true).exists?

      !Gating.claimable_filter(seat_id: seat.id, kind: :task).excluded_task_ids.include?(task.id)
    end

    # The provider group of a credential_providers value; a provider the
    # registry does not list is its own group.
    def provider_group(provider)
      @provider_groups ||= Contract.registry.fetch("credential_providers")
        .to_h { |entry| [ entry.fetch("provider"), entry.fetch("provider_group") ] }.freeze
      @provider_groups.fetch(provider, provider)
    end

    private_class_method :usable?, :passes_for_work?, :task_of, :last_effective_at, :eligible_but_for_accounts?,
      :provider_group
  end
end
