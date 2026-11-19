module Leverage
  # Appends events: the only code that inserts into events (PRD L215-L222;
  # milestone 2 plan §2.1; test/engine/one_writer_test.rb holds it). It runs
  # inside a command's transaction, under the workspace lock that
  # WorkspaceLock took, so seq comes from workspaces.last_seq and seq order
  # is commit order (DB-4). Each payload is validated against its schema,
  # payloads/<type>.v<n>.json, before it is inserted; an invalid event
  # raises and the whole command rolls back. Steps.on_event opens and closes
  # steps in the same call.
  #
  # events.xact_id is left to its default (pg_current_xact_id()): the
  # deferred state trigger refuses, at commit, a task inserted or a
  # tasks.state changed without an event of that task in the same
  # transaction, so every entry that moves a task emits an event with its
  # task.
  module EventLog
    # An event the contract does not allow: an unregistered type, a subject
    # its type does not take, or a payload its schema refuses.
    class InvalidEvent < StandardError; end

    module_function

    # Appends one event and returns the Event.
    #
    # ctx          - the command's Transitions::Context.
    # type         - a registered event type.
    # task:        - the Task the event is about (sets task_id, project_id
    #                and round unless given).
    # subject:     - an Active Record row the event is about, or nil;
    #                subject_kind is its class's name in snake case.
    # payload:     - the payload, with symbol or string keys.
    # actor_kind:, actor_id: - default: the request's caller (Context#actor).
    # command_id:  - default: the request's key.
    # effective_at: - default: ctx.at; a timer's event carries its due time.
    def append(ctx, type:, payload: {}, task: nil, task_id: task&.id, project_id: task&.project_id, round: task&.round,
               subject: nil, subject_kind: subject && kind_of(subject), subject_id: subject&.id, cause_id: nil,
               actor_kind: ctx.actor.first, actor_id: ctx.actor.last, command_id: ctx.request.key,
               effective_at: ctx.at)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      entry = registered(type)
      version = entry.fetch("schema_versions").max
      check_subject(entry, subject_kind)
      check_payload(type, version, payload)

      seq = ctx.workspace.last_seq + 1
      event = Event.create!(workspace_id: ctx.workspace.id, seq: seq, at: ctx.at, effective_at: effective_at, type: type,
        schema_version: version, actor_kind: actor_kind, actor_id: actor_id, project_id: project_id, task_id: task_id,
        round: task_id && round, subject_kind: subject_kind, subject_id: subject_id, cause_id: cause_id,
        command_id: command_id, payload: payload)
      ctx.workspace.update_columns(last_seq: seq)
      Steps.on_event(ctx, event)
      ctx.appended(event, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
      event
    end

    # The subject kind of a row: Review is "review", InboxItem "inbox_item".
    def kind_of(record)
      record.class.name.underscore
    end

    def registered(type)
      Contract.event_type(type)
    rescue KeyError => error
      raise InvalidEvent, error.message
    end

    def check_subject(entry, subject_kind)
      return if entry.fetch("subject_kinds").include?(subject_kind)

      raise InvalidEvent, "#{entry.fetch("type")} takes a subject of #{entry.fetch("subject_kinds").inspect}, " \
                          "not #{subject_kind.inspect}"
    end

    def check_payload(type, version, payload)
      errors = Contract.validate_payload(type, version, payload)
      raise InvalidEvent, "#{type} v#{version} payload: #{errors.join("; ")}" unless errors.empty?
    end
  end
end
