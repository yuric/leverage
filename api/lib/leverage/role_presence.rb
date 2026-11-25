module Leverage
  # Whether a role that claims jobs is online (PRD L401, L402, L909;
  # milestone 4 plan §2.1, The orchestrator's presence, RD-15, RD-16):
  # some enabled, not paused, not removed seat of the role polled within the
  # last 90 seconds, and either connects on its own or has an available
  # candidate (milestone 3 plan §2.1 rule 2). Since when it is not, since
  # when it is, and the account that is the cause. Reads only.
  #
  # The definition is L401's and is not widened for a seat that is busy on
  # a job: the reference runner asks GET /v1/next while its tool runs, and
  # that call records the poll (RD-15). A stopped seat therefore counts as
  # offline 90 seconds after its last recorded poll. With the poll recorded
  # at most every 10 seconds (Transitions::RecordPoll) and the sweep every 15
  # (Sweep::INTERVAL), the Orchestrator offline item opens within 120 seconds
  # of a stop (L909; role_presence_test.rb computes the bound).
  #
  # A seat's own times, all read from rows as they are now:
  #
  #   it stops counting at its last poll plus OFFLINE_AFTER (its connection
  #   when it never polled), or when the last of its candidates stopped
  #   being available (a limit's limited_since, a sign-out's
  #   credential.signed_out), whichever came first;
  #
  #   it counts again from its last poll, or from the reset of the
  #   candidate that came back when that is later.
  #
  # The role is offline since the last of its seats stopped (the workspace's
  # start when it has none, RD-16), and online since the first of its seats
  # that count came back.
  #
  # GA-6 also counts a recently polled General seat that holds an
  # orchestrator job, is idle and would get a waiting check, or is idle
  # while no check waits. For those seats, job queue and holding events
  # mark when the seat could first take work or became unable to take it.
  # Poll and account times still bound that availability.
  module RolePresence
    # The seconds after a seat's last poll at which it stops counting
    # (L401): online while fewer than 90 seconds have passed, so trace 07's
    # item, whose last poll was at -60, is effective at 30.
    OFFLINE_AFTER = 90
    ORCHESTRATOR = "orchestrator".freeze
    CHECK_KINDS = %w[rule_check approval].freeze

    ErroredCheck = Data.define(:hold, :check) do
      def since
        return check.updated_at unless hold

        Event.where(workspace_id: hold.workspace_id, type: "hold.opened", subject_kind: "hold", subject_id: hold.id)
          .pick(:effective_at) || hold.opened_at
      end

      def next_attempt(at)
        Job.new(workspace_id: check.workspace_id, task_id: check.task_id, project_id: check.project_id,
          kind: "rule_check", seat_role: ORCHESTRATOR, target_kind: "rule_check", target_id: check.id,
          state: "queued", queued_at: at)
      end
    end

    WaitingChecks = Data.define(:queued, :errored) do
      def empty? = queued.empty? && errored.empty?
      def count = (queued.map(&:target_id) | errored.map { |entry| entry.check.id }).size
      def since = [ queued.map(&:queued_at).min, *errored.map(&:since) ].compact.min
      def retry_attempts(at) = errored.map { |entry| entry.next_attempt(at) }
    end

    module_function

    # workspace - a Workspace or its id; role - "orchestrator" or
    # "planner"; at - a Time.
    def online?(workspace, role, at, pending_error: nil)
      recent = seats(workspace, role).select { |seat| polled?(seat, at) && candidate_available?(seat, at) }
      return true if recent.any? { |seat| seat.role != "general" }
      return false if recent.empty?

      waiting = waiting_checks(workspace, pending_error: pending_error)
      recent.any? { |seat| general_online?(seat, at, waiting) }
    end

    # The time the role went offline, or nil while it is online.
    def offline_since(workspace, role, at, waiting: nil)
      live = seats(workspace, role)
      return Workspace.find(workspace_id(workspace)).created_at if live.empty?

      waiting ||= waiting_checks(workspace) if live.any? { |seat| seat.role == "general" }
      return nil if live.any? { |seat| seat_online?(seat, at, waiting) }

      live.map { |seat| seat_offline_since(seat, at, waiting) }.max
    end

    # The time the role has been online since, or nil while it is offline.
    def online_since(workspace, role, at, waiting: nil)
      live = online_seats(workspace, role, at, waiting: waiting)
      waiting ||= waiting_checks(workspace) if live.any? { |seat| seat.role == "general" }
      live.map { |seat| seat_online_since(seat, at, waiting) }.min
    end

    def online_seats(workspace, role, at, waiting: nil)
      live = seats(workspace, role)
      waiting ||= waiting_checks(workspace) if live.any? { |seat| seat.role == "general" }
      live.select { |seat| seat_online?(seat, at, waiting) }
    end

    # The Credential that is the cause when every seat of the role is held
    # back by its own account (L401: limited or signed out, with no
    # candidate available), else nil: the first such seat's own login.
    def cause_credential(workspace, role, at)
      live = seats(workspace, role)
      return nil if live.empty?
      return nil unless live.all? { |seat| seat.credential_id && !candidate_available?(seat, at) }

      Credential.find_by(id: live.first.credential_id, workspace_id: live.first.workspace_id)
    end

    # The seats that may count: enabled, not paused, not removed, oldest
    # first.
    def seats(workspace, role)
      enabled_seats(workspace, role).where(paused: false).order(:created_at, :id).to_a
    end

    def configured?(workspace, role) = enabled_seats(workspace, role).exists?

    def enabled_seats(workspace, role)
      roles = role.to_s == ORCHESTRATOR ? Roles.roles_acting_as(ORCHESTRATOR) : role.to_s
      Seat.where(workspace_id: workspace_id(workspace), role: roles, enabled: true, may_work: true, removed_at: nil)
    end

    def seat_online?(seat, at, waiting = nil)
      return false unless polled?(seat, at) && candidate_available?(seat, at)

      seat.role != "general" || general_online?(seat, at, waiting || waiting_checks(seat.workspace_id))
    end

    # The same waiting set drives presence and the workspace timer.
    # A fresh check_error is included while Gate is opening
    # its hold, so a seat barred from the check stays offline across the miss.
    def waiting_checks(workspace, pending_error: nil)
      id = workspace_id(workspace)
      queued = Job.where(workspace_id: id, kind: CHECK_KINDS, state: "queued").select(:target_id, :queued_at).to_a
      errored = Hold.where(workspace_id: id, reason: "check_error", closed_at: nil).order(:opened_at, :id).filter_map do |hold|
        check = hold.rule_check_id && RuleCheck.find_by(id: hold.rule_check_id, workspace_id: id)
        check ||= RuleCheck.where(workspace_id: id, task_id: hold.task_id, rule_id: hold.rule_id).order(:updated_at, :id).last
        ErroredCheck.new(hold: hold, check: check) if check&.result == "error" && !Transitions::Gate.approval_check?(check)
      end
      errored << ErroredCheck.new(hold: nil, check: pending_error) if pending_error
      WaitingChecks.new(queued: queued, errored: errored)
    end

    def general_online?(seat, at, waiting)
      held = Jobs.held(seat, at)
      return held.seat_role == ORCHESTRATOR if held
      return false if Eligibility.holds_anything?(seat, at: at)
      return true if waiting.empty?

      CHECK_KINDS.include?(Jobs.next_for(seat, at: at, additional: waiting.retry_attempts(at))&.kind)
    end

    # Polled within the last OFFLINE_AFTER seconds.
    def polled?(seat, at) = !seat.last_polled_at.nil? && seat.last_polled_at > at - OFFLINE_AFTER

    # A seat that connects on its own always has one (it runs on no
    # account the app knows).
    def candidate_available?(seat, at) = seat.credential_id.nil? || !Candidates.first_available(seat, nil, at).nil?

    # When a seat that does not count now stopped counting: the earlier of
    # the times each failing condition began.
    def seat_offline_since(seat, at, waiting)
      times = []
      times << (seat.last_polled_at ? seat.last_polled_at + OFFLINE_AFTER : seat.created_at) unless polled?(seat, at)
      times << accounts_unavailable_since(seat) unless candidate_available?(seat, at)
      times << general_blocked_since(seat, at, waiting) if seat.role == "general" && !general_online?(seat, at, waiting)
      times.compact.min || seat.created_at
    end

    # When a seat that counts now began to: its last poll, or the reset of
    # the first of its available candidates when that came later.
    def seat_online_since(seat, at, waiting)
      since = seat.last_polled_at
      since = [ since, general_available_since(seat, at, waiting) ].compact.max if seat.role == "general"
      return since if seat.credential_id.nil?

      reset = Candidates.for(seat).select { |credential| Candidates.available?(credential, at) }
        .map { |credential| credential.limited_since && credential.limited_until }
      reset = reset.include?(nil) ? nil : reset.compact.min
      [ since, reset ].compact.max
    end

    def general_blocked_since(seat, at, waiting)
      held = Jobs.held(seat, at)
      return held.claimed_at if held

      events = Event.where(workspace_id: seat.workspace_id)
      task_ids = Task.where(workspace_id: seat.workspace_id, holder_seat_id: seat.id).select(:id)
      review_ids = Review.where(workspace_id: seat.workspace_id, reviewer_seat_id: seat.id, verdict: nil).select(:id)
      task_grant = events.where(task_id: task_ids)
        .where("(type = :grant AND payload->>'seat_id' = :seat) OR payload->>'lease_seat_id' = :seat", grant: Leases::BUILDER_GRANT, seat: seat.id)
      review_grant = events.where(type: "review.started", subject_id: review_ids, actor_id: seat.id)
      pending_ids = PendingTransition.where(workspace_id: seat.workspace_id, requester_id: seat.id, command: "claim", state: "pending")
        .select(Arel.sql("id::text"))
      pending_grant = events.where(type: "check.queued").where("payload->>'pending_transition_id' IN (#{pending_ids.to_sql})")
      approved = events.where(type: %w[action.approved action.waived], task_id: Finishing.waiting_for(seat).map(&:id))
      blocked = [ task_grant, review_grant, pending_grant, approved ].filter_map { |scope| scope.maximum(:effective_at) }.max
      blocked || waiting.since
    end

    def general_available_since(seat, at, waiting)
      job = Jobs.held(seat, at)
      return job.claimed_at if job

      next_job = Jobs.next_for(seat, at: at, additional: waiting.retry_attempts(at)) unless waiting.empty?
      queued_at = if next_job&.new_record?
        waiting.errored.find { |entry| entry.check.id == next_job.target_id }&.since
      else
        next_job&.queued_at
      end
      finished_job = Job.where(workspace_id: seat.workspace_id, claimed_by_seat_id: seat.id).maximum(:finished_at)
      finished_work = Event.where(workspace_id: seat.workspace_id, actor_kind: "seat", actor_id: seat.id,
        type: %w[task.released task.submitted review.released review.passed review.failed]).maximum(:effective_at)
      [ queued_at, finished_job, finished_work ].compact.max
    end

    # When the last of the seat's candidates stopped being available: its
    # limit's start, or its sign-out's effective time. A seat with no
    # candidate at all has had none since it was connected.
    def accounts_unavailable_since(seat)
      candidates = Candidates.for(seat)
      return seat.created_at if candidates.empty?

      candidates.map { |credential| unavailable_since(credential) }.max
    end

    def unavailable_since(credential)
      return credential.limited_since if credential.state == "active"

      Event.where(workspace_id: credential.workspace_id, type: "credential.signed_out", subject_kind: "credential",
        subject_id: credential.id).maximum(:effective_at) || credential.updated_at
    end

    def workspace_id(workspace) = workspace.respond_to?(:id) ? workspace.id : workspace

    private_class_method :enabled_seats, :general_online?, :general_blocked_since, :general_available_since
  end
end
