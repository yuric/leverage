require "digest"

module Leverage
  # The briefing (PRD, The briefing L466-L478; milestone 2 plan EN-6; DB-11):
  # what a seat must read before it works on a task or a review.
  #
  # Its parts, each with a version: the project brief (empty, version 0,
  # while tasks have no project, SC-8), the seat's role file (RoleFiles,
  # version the release) and the task's contract (contract_version), then
  # the rules Gating.briefing_rules returns, each as {kind: "rule", id:
  # the rule's id, version: its current version number} (milestone 4,
  # L470, L476). The hash is SHA-256 in lower-case hex over
  # Gating::CanonicalJson.dump of the parts as {kind, id, version}, in that
  # order: only a change to a part of this task's briefing changes it, so
  # saving, switching or removing a rule in it does, and nothing else
  # about rules does. The work reference and a failed review's notes are
  # outside it.
  #
  # The answer's rules carry each rule's version id, key, name and text: a
  # model rule's instruction, or an app rule's sentence (Rules::Sentences,
  # milestone 4 plan RD-62), and may_apply for a "let the checker decide"
  # rule.
  #
  # An acknowledgement is kept per seat, per lease and per hash
  # (briefing_acknowledgements), the lease named by the event that granted
  # it: for a builder the latest event of the task that names the seat in
  # task.claimed's seat_id or in a lease_seat_id; for a reviewer the latest
  # review.started of the review by that seat.
  #
  # It reads and writes nothing else: the entries write the rows, and the
  # reads (get_task_briefing, GET /v1/next) call it outside any command.
  module Briefing
    module_function

    # The hash of the briefing the seat would read now.
    #
    # subject - the Task, or the Review a reviewer holds.
    # seat    - the Seat; positional or keyword.
    # review: - the Review, when subject is its Task.
    def hash_for(subject, positional_seat = nil, seat: positional_seat, review: nil)
      task, review = task_and_review(subject, review)
      Digest::SHA256.hexdigest(Gating::CanonicalJson.dump(parts(task, seat, review)))
    end

    # The briefing in the contract's Briefing shape (string keys).
    def for(subject, positional_seat = nil, seat: positional_seat, review: nil)
      task, review = task_and_review(subject, review)
      rules = briefing_rules(task, seat, review)
      {
        "hash" => hash_for(task, seat: seat, review: review),
        "versions" => {
          "rule_version_ids" => rules.map { |rule| rule.fetch("rule_version_id") },
          "brief_version" => brief_version(task),
          "role_file_version" => RoleFiles.version,
          "contract_version" => task.contract_version
        },
        "rules" => rules,
        "brief" => [],
        "role_file" => RoleFiles.text(seat.role),
        "contract" => contract(task)
      }
    end

    # The same; the name the agent reads call it by.
    def build(subject, positional_seat = nil, seat: positional_seat, review: nil)
      self.for(subject, seat: seat, review: review)
    end

    # The contract's BriefingResponse: the briefing, the work reference and,
    # for the builder, the notes of the task's failed reviews, oldest first
    # (Q-9). A reviewer's briefing has none.
    def response(subject, positional_seat = nil, seat: positional_seat, review: nil)
      task, review = task_and_review(subject, review)
      notes = review ? [] : review_notes(task)
      { "briefing" => self.for(task, seat: seat, review: review), "work_reference" => task.work_reference,
        "review_notes" => notes }
    end

    # The notes of the task's failed reviews, oldest round first. A review
    # failed by a rule at "when the review has passed" (failed_rule_check_id)
    # carries, after the reviewer's notes, the rule's name, as the version
    # the check ran against names it, and the check's reason (milestone 4
    # plan RD-38). Both are content the runner quotes, never instructions.
    def review_notes(task)
      reviews = Review.where(workspace_id: task.workspace_id, task_id: task.id, verdict: "failed").order(:round, :created_at)
      failed = failed_rule_notes(task, reviews.filter_map(&:failed_rule_check_id))
      reviews.map do |review|
        notes = [ review.notes.presence, failed[review.failed_rule_check_id] ].compact.join("\n\n").presence || review.notes
        { "review_id" => review.id, "round" => review.round, "notes" => notes }
      end
    end

    # The event that granted the seat its latest lease on the task (a
    # builder) or on the review (a reviewer), or nil.
    def lease_event(subject, positional_seat = nil, seat: positional_seat, review: nil)
      task, review = task_and_review(subject, review)
      events = Event.where(workspace_id: task.workspace_id, task_id: task.id)
      if review
        events.where(type: "review.started", subject_kind: "review", subject_id: review.id, actor_id: seat.id)
          .order(:seq).last
      else
        events.where("(type = ? AND payload ->> 'seat_id' = ?) OR payload ->> 'lease_seat_id' = ?",
          Leases::BUILDER_GRANT, seat.id, seat.id).order(:seq).last
      end
    end

    # Whether the seat has acknowledged the briefing under its latest lease:
    # :current (this hash), :changed (only another hash, L474) or :missing
    # (none under this lease, L473).
    def acknowledgement(subject, positional_seat = nil, seat: positional_seat, review: nil)
      task, review = task_and_review(subject, review)
      lease = lease_event(task, seat: seat, review: review)
      return :missing unless lease

      hashes = BriefingAcknowledgement.where(workspace_id: task.workspace_id, seat_id: seat.id, task_id: task.id,
        review_id: review&.id, lease_event_id: lease.id).pluck(:briefing_hash)
      return :missing if hashes.empty?

      hashes.include?(hash_for(task, seat: seat, review: review)) ? :current : :changed
    end

    # The parts the hash covers, in order.
    def parts(task, seat, review)
      [
        { "kind" => "brief", "id" => task.project_id, "version" => brief_version(task) },
        { "kind" => "role_file", "id" => seat.role, "version" => RoleFiles.version },
        { "kind" => "contract", "id" => task.id, "version" => task.contract_version }
      ] + rule_parts(task, seat, review)
    end

    def rule_parts(task, seat, review)
      Gating.briefing_rules(task_id: task.id, seat_id: seat.id, review_id: review&.id)
        .map { |part| { "kind" => part.kind.to_s, "id" => part.id, "version" => part.version } }
    end

    # The briefing's rules in the contract's BriefingRule shape, in the
    # order Gating.briefing_rules gives them.
    def briefing_rules(task, seat, review)
      parts = Gating.briefing_rules(task_id: task.id, seat_id: seat.id, review_id: review&.id)
      return [] if parts.empty?

      versions = RuleVersion.where(workspace_id: task.workspace_id, rule_id: parts.map(&:id))
        .index_by { |version| [ version.rule_id, version.version ] }
      parts.map do |part|
        version = versions.fetch([ part.id, part.version ])
        { "rule_id" => part.id, "rule_version_id" => version.id, "key" => version.key, "name" => version.name,
          "instruction" => version.checker == "app" ? Rules::Sentences.for(version) : version.instruction,
          "may_apply" => part.may_apply }
      end
    end

    # "<rule name>: <reason>" for each failed rule check, by its id.
    def failed_rule_notes(task, check_ids)
      return {} if check_ids.empty?

      checks = RuleCheck.where(workspace_id: task.workspace_id, id: check_ids).to_a
      names = RuleVersion.where(id: checks.map(&:rule_version_id)).pluck(:id, :name).to_h
      checks.to_h { |check| [ check.id, "#{names[check.rule_version_id]}: #{check.reason.presence || "No reason given."}" ] }
    end

    # The project brief's version: 0 while the task has no project.
    def brief_version(task)
      return 0 unless task.project_id

      Project.where(id: task.project_id).pick(:brief_version) || 0
    end

    # The contract part (IF-25): the goal, the details, the criteria in
    # order with their evidence, and the outward actions (none in milestone
    # 2, SC-3).
    def contract(task)
      criteria = Criterion.where(workspace_id: task.workspace_id, task_id: task.id, removed_at: nil).order(:position).to_a
      evidence = Evidence.where(workspace_id: task.workspace_id, criterion_id: criteria.map(&:id)).order(:created_at, :id)
        .group_by(&:criterion_id)
      {
        "contract_version" => task.contract_version,
        "goal" => task.goal.to_s,
        "details" => task.details,
        "criteria" => criteria.map { |criterion| criterion_json(criterion, evidence.fetch(criterion.id, [])) },
        "actions" => []
      }
    end

    def criterion_json(criterion, evidence)
      {
        "id" => criterion.id, "task_id" => criterion.task_id, "position" => criterion.position,
        "text" => criterion.text.to_s, "kind" => criterion.kind, "state" => criterion.state,
        "passed_at" => criterion.passed_at&.utc&.iso8601(6), "passed_by_seat_id" => criterion.passed_by_seat_id,
        "evidence" => evidence.map do |row|
          { "id" => row.id, "criterion_id" => row.criterion_id, "kind" => row.kind, "value" => row.value.to_s }
        end
      }
    end

    def task_and_review(subject, review)
      return [ Task.find_by!(workspace_id: subject.workspace_id, id: subject.task_id), subject ] if subject.is_a?(Review)

      [ subject, review ]
    end

    private_class_method :parts, :rule_parts, :briefing_rules, :failed_rule_notes, :brief_version, :contract, :criterion_json,
      :task_and_review
  end
end
