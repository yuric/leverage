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
  module RolePresence
    # The seconds after a seat's last poll at which it stops counting
    # (L401): online while fewer than 90 seconds have passed, so trace 07's
    # item, whose last poll was at -60, is effective at 30.
    OFFLINE_AFTER = 90

    module_function

    # workspace - a Workspace or its id; role - "orchestrator" or
    # "planner"; at - a Time.
    def online?(workspace, role, at)
      seats(workspace, role).any? { |seat| seat_online?(seat, at) }
    end

    # The time the role went offline, or nil while it is online.
    def offline_since(workspace, role, at)
      live = seats(workspace, role)
      return nil if live.any? { |seat| seat_online?(seat, at) }
      return Workspace.find(workspace_id(workspace)).created_at if live.empty?

      live.map { |seat| seat_offline_since(seat, at) }.max
    end

    # The time the role has been online since, or nil while it is offline.
    def online_since(workspace, role, at)
      seats(workspace, role).select { |seat| seat_online?(seat, at) }.map { |seat| seat_online_since(seat, at) }.min
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
      Seat.where(workspace_id: workspace_id(workspace), role: role.to_s, enabled: true, paused: false, removed_at: nil)
        .order(:created_at, :id).to_a
    end

    def seat_online?(seat, at) = polled?(seat, at) && candidate_available?(seat, at)

    # Polled within the last OFFLINE_AFTER seconds.
    def polled?(seat, at) = !seat.last_polled_at.nil? && seat.last_polled_at > at - OFFLINE_AFTER

    # A seat that connects on its own always has one (it runs on no
    # account the app knows).
    def candidate_available?(seat, at) = seat.credential_id.nil? || !Candidates.first_available(seat, nil, at).nil?

    # When a seat that does not count now stopped counting: the earlier of
    # the times each failing condition began.
    def seat_offline_since(seat, at)
      times = []
      times << (seat.last_polled_at ? seat.last_polled_at + OFFLINE_AFTER : seat.created_at) unless polled?(seat, at)
      times << accounts_unavailable_since(seat) unless candidate_available?(seat, at)
      times.min
    end

    # When a seat that counts now began to: its last poll, or the reset of
    # the first of its available candidates when that came later.
    def seat_online_since(seat, at)
      return seat.last_polled_at if seat.credential_id.nil?

      reset = Candidates.for(seat).select { |credential| Candidates.available?(credential, at) }
        .map { |credential| credential.limited_since && credential.limited_until }
      reset = reset.include?(nil) ? nil : reset.compact.min
      [ seat.last_polled_at, reset ].compact.max
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
  end
end
