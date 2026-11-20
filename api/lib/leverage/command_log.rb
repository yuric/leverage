module Leverage
  # One log line per command (PRD L829, L832; milestone 2 plan IN-34, EN-19;
  # milestone 4 plan RT-8, §0.1 fact 19): the command, the caller's kind and
  # id, the key, the outcome, the refusal code, and four timings in
  # milliseconds: the wait for the workspace lock, the time spent writing
  # events and steps (EventLog.append with Steps.on_event and the counter
  # update), the whole transition, and the time inside Transitions::Gate
  # (asking the rules and writing their checks). Last, the rule a
  # blocked_by_rule refusal names (else "-"). Never a header, a body, a
  # refusal's reason, a rule's instruction or any task text: the line is
  # built from these fields alone. The fields of milestone 2 come first, in
  # their order; scripts/speed_report.py reads the timings by name.
  #
  #   leverage.command command=claim caller=seat:<id> key=<key> outcome=completed refusal=- lock_wait_ms=0.412 event_step_ms=1.087 transition_ms=4.250 gate_ms=0.950 rule=-
  module CommandLog
    PREFIX = "leverage.command".freeze

    module_function

    def write(request, outcome, lock_wait:, writes:, total:, gate: 0.0)
      Rails.logger.info(line(request, outcome, lock_wait: lock_wait, writes: writes, total: total, gate: gate))
    end

    def line(request, outcome, lock_wait:, writes:, total:, gate: 0.0)
      caller = request.by_app? ? "app" : "#{request.caller_kind}:#{request.caller_id || "-"}"
      refusal = outcome.refusal
      [ PREFIX, "command=#{request.command}", "caller=#{caller}", "key=#{request.key || "-"}",
        "outcome=#{outcome.outcome}", "refusal=#{refusal&.code || "-"}", "lock_wait_ms=#{ms(lock_wait)}",
        "event_step_ms=#{ms(writes)}", "transition_ms=#{ms(total)}", "gate_ms=#{ms(gate)}",
        "rule=#{refusal&.rule_id || "-"}" ].join(" ")
    end

    def ms(seconds) = format("%.3f", seconds * 1000)
  end
end
