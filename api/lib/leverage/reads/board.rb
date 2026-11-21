module Leverage
  module Reads
    # The board (get_board; milestone 2 plan MA-20, MA-29, SC-11): every task
    # of the workspace with whether it is blocked, why, which credential it
    # waits for and the Needs you item it has open. One snapshot, so the
    # cards and as_of_seq are one moment of the log. The app puts the cards
    # in its six lanes and filters them; the read does not.
    #
    # A card names the account a task waits for, and when it resets, in one
    # of three cases (milestone 3 plan HM-40, HE-15, HE-16):
    #
    # - a hold names a credential (credential_limit, credential_signed_out):
    #   that account, and its reset time unless it is signed out;
    # - a Ready task with no hold whose wait_ready step names
    #   credential_limit: no builder can take it for want of an account
    #   (HE-35), so the account that resets first, or the limited one when
    #   none has a reset time (the time is null); and, with or without that
    #   step, an account found signed out when every builder's candidates
    #   are unavailable, which opens no item (HE-16);
    # - a task In review whose open review no reviewer can begin because
    #   every reviewer seat's candidates are limited or signed out, which
    #   waits with no item and no hold (HE-15): the same choice of account.
    #
    # The app writes the sentence from the account's name and state and the
    # time, as it does MA-29's. The task page (TaskPage) names it with the
    # same two fields, from the same call to waiting, so the page and the
    # card always agree.
    #
    # Milestone 4 (its plan §2.3, RD-27) adds two fields a Backlog card
    # speaks from: checking, while a transition of the task is pending and
    # no hold is open ("Checking the details"; while a hold is open the
    # hold's waiting step is open instead, L378), and check_reason, the
    # reason of the failed check behind an open contract_incomplete hold
    # ("Needs details"). Which transition of a task is pending is
    # pending_transitions, which the task page reads too.
    module Board
      module_function

      # Raises ActiveRecord::RecordNotFound for an unknown workspace.
      def call(workspace_id)
        Snapshot.call(workspace_id) do |as_of_seq|
          tasks = Task.where(workspace_id: workspace_id).order(:created_at, :id).to_a
          task_ids = tasks.map(&:id)
          holds = Hold.where(workspace_id: workspace_id, task_id: task_ids, closed_at: nil).order(:opened_at, :id).group_by(&:task_id)
          items = InboxItem.where(workspace_id: workspace_id, about_kind: "task", about_id: task_ids, state: "open")
            .order(:opened_at, :id).to_a
          item_json = inbox_items(workspace_id, items).group_by { |item| item.fetch(:about_id) }
          waits = waiting(workspace_id, tasks, holds)
          pending = pending_transitions(workspace_id, task_ids)
          reasons = check_reasons(holds.values.flatten)
          finishing = tasks.select { |task| task.state == "finishing" && task.holder_seat_id.nil? }
          waiting_builders = Action.where(workspace_id: workspace_id, task_id: finishing.map(&:id), state: "approved")
            .distinct.pluck(:task_id).to_set

          { tasks: tasks.map do |task|
              open = holds.fetch(task.id, [])
              card(task, open, item_json[task.id]&.first, waits.fetch(task.id))
                .merge(checking: pending.key?(task.id) && open.empty?, check_reason: check_reason(open, reasons),
                  waits_for_builder: waiting_builders.include?(task.id),
                  waits_for_stronger_agent: task.state == "ready" && !task.minimum_strength_rank.nil?)
            end,
            as_of_seq: as_of_seq, reviewer_seat_exists: reviewer_seat?(workspace_id) }
        end
      end

      # Whether the workspace has a reviewer seat that is not removed: the
      # board and the task page say so when it has none (SC-11).
      def reviewer_seat?(workspace_id)
        Seat.where(workspace_id: workspace_id, role: "reviewer", removed_at: nil).exists?
      end

      # The Needs you items as the contract has them, each with the seq of its
      # inbox.opened event (the item's subject).
      def inbox_items(workspace_id, items)
        seqs = Event.where(workspace_id: workspace_id, type: "inbox.opened", subject_id: items.map(&:id))
          .pluck(:subject_id, :seq).to_h
        Inbox.shapes(workspace_id, items.map { |item| [ item, seqs.fetch(item.id) ] })
      end

      # task id => its pending PendingTransition (L373: at most one).
      def pending_transitions(workspace_id, task_ids)
        PendingTransition.where(workspace_id: workspace_id, task_id: task_ids, state: "pending").order(:created_at, :id)
          .index_by(&:task_id)
      end

      # rule check id => reason, for the checks the open contract_incomplete
      # holds name.
      def check_reasons(open_holds)
        ids = open_holds.select { |hold| hold.reason == "contract_incomplete" }.filter_map(&:rule_check_id)
        RuleCheck.where(id: ids).pluck(:id, :reason).to_h
      end

      # The reason of the failed check behind the task's oldest open
      # contract_incomplete hold, or nil.
      def check_reason(open_holds, reasons)
        hold = open_holds.find { |candidate| candidate.reason == "contract_incomplete" && candidate.rule_check_id }
        hold && reasons[hold.rule_check_id]
      end

      def card(task, holds, item, waiting)
        { task: Shapes.task_summary(task), blocked: holds.any?, hold_reasons: holds.map(&:reason).uniq,
          **waiting, inbox_item: item }
      end

      # The account each task waits for and when it resets, as the card and
      # the task page say it: task id => { waiting_for_credential_id:,
      # waiting_until: }. open_holds maps a task id to its open holds. A hold
      # that names a credential says which, and its reset time only while
      # the account is active; a task with no hold asks AccountWaits.
      def waiting(workspace_id, tasks, open_holds)
        held = tasks.to_h { |task| [ task.id, open_holds.fetch(task.id, []).find(&:credential_id) ] }.compact
        credentials = Credential.where(id: held.values.map(&:credential_id)).index_by(&:id)
        waits = AccountWaits.new(workspace_id, tasks.select { |task| open_holds.fetch(task.id, []).empty? })

        tasks.to_h do |task|
          account, until_ = if (hold = held[task.id])
            credential = credentials[hold.credential_id]
            [ hold.credential_id, (credential.limited_until if credential && credential.state == "active") ]
          else
            waits.for(task)
          end
          [ task.id, { waiting_for_credential_id: account, waiting_until: Shapes.time(until_) } ]
        end
      end

      # Which account a Ready or In review task with no hold waits for
      # (HM-40, HE-15, HE-16). It loads what it needs once and answers for
      # each task from Candidates, the one reading of L672.
      class AccountWaits
        def initialize(workspace_id, tasks)
          @now = ActiveRecord::Base.lease_connection.select_value("SELECT clock_timestamp()")
          # tasks are the ones with no hold: a held task's card says what its hold says.
          @ready = tasks.select { |task| task.state == "ready" }
          @in_review = tasks.select { |task| task.state == "in_review" }
          @asked = (@ready + @in_review).to_set(&:id)
          @builders = seats(workspace_id, "builder") if @ready.any?
          @reviewers = seats(workspace_id, "reviewer") if @in_review.any?
          @causes = TaskStep.where(task_id: @ready.map(&:id), closed_at: nil, kind: "wait_ready").pluck(:task_id, :cause_kind).to_h
          @reviews = Review.where(task_id: @in_review.map(&:id), verdict: nil, reviewer_seat_id: nil).order(:round, :created_at, :id)
            .index_by(&:task_id)
          @memo = {}
        end

        # [credential_id, reset time], or nil: the task waits for no account.
        def for(task)
          return nil unless @asked.include?(task.id)

          case task.state
          when "ready" then ready(task)
          when "in_review" then in_review(task)
          end
        end

        private

        def seats(workspace_id, role)
          Seat.where(workspace_id: workspace_id, role: role, enabled: true, paused: false, removed_at: nil)
            .order(:created_at, :id).to_a
        end

        def ready(task)
          seats = @builders.select { |seat| task.minimum_strength_rank.nil? || seat.strength_rank >= task.minimum_strength_rank }
          key = [ task.minimum_strength_rank, @causes[task.id] ]
          @memo.fetch(key) { @memo[key] = account(seats, task, limit: @causes[task.id] == "credential_limit") }
        end

        def in_review(task)
          review = @reviews[task.id]
          review && account(@reviewers, review, limit: true)
        end

        # The account a piece of work waits for, when every seat has
        # candidates and none of them is available for it: with limit, the
        # one that resets first, else a signed-out one, else a limited one
        # with no reset time; without limit, a signed-out one only.
        def account(seats, work, limit:)
          return nil if seats.empty? || seats.any? { |seat| seat.credential_id.nil? || Candidates.first_available(seat, work, @now) }

          all = seats.flat_map { |seat| Candidates.for(seat) }
          reset = limit && seats.filter_map { |seat| Candidates.earliest_reset(seat, work, @now) }
            .min_by { |credential| [ credential.limited_until, credential.position ] }
          return [ reset.id, reset.limited_until ] if reset

          signed_out = all.find { |credential| credential.state == "signed_out" }
          return [ signed_out.id, nil ] if signed_out

          open_ended = limit && all.find { |credential| credential.limited?(@now) }
          [ open_ended.id, nil ] if open_ended
        end
      end
    end
  end
end
