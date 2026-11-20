require_relative "accounts_support"

# What the tests of the handoff entries share (milestone 3 plan WP3): the
# helper's two reports as the helper's controller builds them, the
# credential_hold_release timer as the sweep runs it, and a spy on the stubs
# of other packages that WP3 only calls (SeatRuns.ensure_run_on and
# SeatRuns.ended_by_interruption, WP5's): the spy records each call and then
# runs the method as it is, so a test holds whether the stub or the finished
# method is in place. Every value is made up.
module HandoffSupport
  include AccountsSupport

  # The body of POST /v1/helper/credentials/{id}/limit-reached plus the
  # path's id, as V1::Helper::CredentialsController passes it.
  def limit_params(credential, seat, task: nil, review: nil, job_id: nil, reset_at: nil, observed_at: nil,
                   window: "five_hour")
    observed_at ||= scenario.database_now
    { "id" => credential.id, "credential_id" => credential.id, "seat_id" => seat.id, "task_id" => task&.id,
      "review_id" => review&.id, "job_id" => job_id, "window" => window, "reset_at" => reset_at&.utc&.iso8601(6),
      "observed_at" => observed_at.utc.iso8601(6), "tool_version" => "0.0.0-example" }
  end

  # The body of POST /v1/helper/credentials/{id}/signed-out plus the path's
  # id.
  def signed_out_params(credential, seat, task: nil, review: nil, job_id: nil)
    { "id" => credential.id, "credential_id" => credential.id, "seat_id" => seat.id, "task_id" => task&.id,
      "review_id" => review&.id, "job_id" => job_id, "observed_at" => scenario.database_now.utc.iso8601(6),
      "tool_version" => "0.0.0-example" }
  end

  def report_limit(credential, seat, key: new_key, **options)
    helper_command("report_limit", limit_params(credential, seat, **options), key: key)
  end

  def report_signed_out(credential, seat, key: new_key, **options)
    helper_command("report_signed_out", signed_out_params(credential, seat, **options), key: key)
  end

  # The credential_hold_release timer as its own command (the sweep's): no
  # caller, no key.
  def release_timer(params = {})
    T.apply(T::Request.new(command: "credential_hold_release", workspace_id: scenario.workspace_id, caller_kind: nil,
      caller_id: nil, key: nil, request_hash: nil, params: params))
  end

  # Records every call of a module function while the block runs, then
  # runs the method as it is. Returns the calls, each an Array of the
  # arguments.
  def spying(mod, name)
    calls = []
    original = mod.method(name)
    mod.define_singleton_method(name) do |*args, **kwargs, &block|
      calls << (kwargs.empty? ? args : args + [ kwargs ])
      original.call(*args, **kwargs, &block)
    end
    yield calls
    calls
  ensure
    mod.define_singleton_method(name, original) if original
  end

  # The ensure_run_on calls the block makes, each [seat_id, credential_id,
  # work], work being the Task or Review as [class name, id].
  def runs_ensured(&block)
    calls = spying(Leverage::SeatRuns, :ensure_run_on, &block)
    calls.map { |(_ctx, seat, credential, work)| [ seat.id, credential&.id, work && [ work.class.name, work.id ] ] }
  end

  # The ended_by_interruption calls the block makes, each [seat_id, reason].
  def runs_ended(&block)
    spying(Leverage::SeatRuns, :ended_by_interruption, &block).map { |(seat, reason)| [ seat.id, reason ] }
  end

  # The open hold of a task, or nil.
  def open_hold(task) = Hold.find_by(task_id: task.id, closed_at: nil)

  # The [type, subject_id] pairs of events, for an order assertion.
  def typed(events) = events.map { |event| [ event.type, event.subject_id ] }

  # A time in the database's clock, offset by seconds.
  def from_now(seconds) = scenario.database_now + seconds
end
