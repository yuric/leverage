module Leverage
  # One log line per command (PRD L829; milestone 2 plan IN-34, EN-19): the
  # command, the caller's kind and id, the key, the outcome, the refusal
  # code, and three timings in milliseconds: the wait for the workspace
  # lock, the time spent writing events and steps (EventLog.append with
  # Steps.on_event and the counter update), and the whole transition.
  # Never a header or a body. scripts/speed_report.py reads these lines.
  #
  #   leverage.command command=claim caller=seat:<id> key=<key> outcome=completed refusal=- lock_wait_ms=0.412 event_step_ms=1.087 transition_ms=4.250
  module CommandLog
    PREFIX = "leverage.command".freeze

    module_function

    def write(request, outcome, lock_wait:, writes:, total:, gate: 0.0)
      Rails.logger.info(line(request, outcome, lock_wait: lock_wait, writes: writes, total: total))
    end

    def line(request, outcome, lock_wait:, writes:, total:, gate: 0.0)
      caller = request.by_app? ? "app" : "#{request.caller_kind}:#{request.caller_id || "-"}"
      [ PREFIX, "command=#{request.command}", "caller=#{caller}", "key=#{request.key || "-"}",
        "outcome=#{outcome.outcome}", "refusal=#{outcome.refusal&.code || "-"}", "lock_wait_ms=#{ms(lock_wait)}",
        "event_step_ms=#{ms(writes)}", "transition_ms=#{ms(total)}" ].join(" ")
    end

    def ms(seconds) = format("%.3f", seconds * 1000)
  end
end
