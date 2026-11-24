require "test_helper"
require_relative "accounts_support"
require_relative "call_spy"

# report_request_result (PRD L600-L608; milestone 2 plan IN-23 to IN-25,
# CL-18): the helper reports a request's outcome. An add whose checks all
# passed becomes an added credential with credential.added; a failed add
# deletes the row. Verify writes credential.verified, or
# credential.signed_out when the sign-in check fails, and nothing for any
# other failure. A plan or an account email goes to the credential's row and
# never into an event or the stored result.
#
# Milestone 3 (plan HE-2, HE-10, HE-11, HE-29, HE-36): a Sign in again
# (open_sign_in) reports as Verify does; a passed Verify or sign-in clears
# a limit that has no reset time and leaves one with a reset time alone;
# after credential.verified, credential.added and credential.signed_out
# the open credential holds are looked at again (Handoff.reevaluate).
class ReportRequestResultTest < ActiveSupport::TestCase
  include AccountsSupport
  include CallSpy

  setup { use_scenario }

  def adding(provider: "claude")
    credential = @scenario.credential(provider: provider, added: false)
    request = queue_request("run_add_checks", credential: credential, state: "picked_up",
      params: { "provider" => provider, "credential_kind" => "login" })
    [ credential, request ]
  end

  def report(request, result, **options)
    helper_command("report_request_result", { "id" => request.id, "result" => result }, **options)
  end

  test "an add whose checks all passed becomes active and writes credential.added as the app, with the helper's key" do
    credential, request = adding
    written = events_written { assert_completed(report(request, result_body, key: "add-passed-key")) }

    credential.reload
    assert_equal "active", credential.state
    assert_not_nil credential.last_verified_at
    assert_equal [ "credential.added" ], written.map(&:type)
    event = written.first
    assert_equal [ "credential", credential.id, "app", @scenario.helper.id, "add-passed-key", {} ],
      [ event.subject_kind, event.subject_id, event.actor_kind, event.actor_id, event.command_id, event.payload ]
    assert_equal credential.last_verified_at, event.at
    request.reload
    assert_equal [ "finished", "finished" ], [ request.state, request.result.fetch("outcome") ]
    assert_equal event.at, request.finished_at
  end

  test "a passed login add places it above the first added token and queues its first read (CR-13, CR-29)" do
    login = @scenario.credential
    first_token = @scenario.token_credential
    second_token = @scenario.token_credential(provider: "claude_api")
    credential, request = adding

    written = events_written { assert_completed(report(request, result_body)) }

    assert_equal [ 1, 2, 3, 4 ], [ login, credential, first_token, second_token ].map { |row| row.reload.position }
    assert_equal [ "credential.added" ], written.map(&:type)
    assert_first_read(credential, at: written.first.at)
  end

  test "a passed token add places it last and queues its first read (CR-13, CR-29)" do
    credential = @scenario.token_credential(added: false)
    login = @scenario.credential
    request = queue_request("run_add_checks", credential: credential, state: "picked_up",
      params: { "provider" => credential.provider, "credential_kind" => credential.kind })

    written = events_written do
      assert_completed(report(request, result_body(checks: [ check("token_works") ], tool_version: nil)))
    end

    assert_equal [ "credential.added" ], written.map(&:type)
    placed_ids = Credential.where(workspace_id: @scenario.workspace_id).order(:position).pluck(:id)
    assert_equal [ login.id, credential.id ], placed_ids
    assert_equal "active", credential.reload.state
    assert_first_read(credential, at: written.first.at)
  end

  def assert_first_read(credential, at:)
    reads = HelperRequest.where(workspace_id: @scenario.workspace_id, kind: "read_usage")
    assert_equal [ [ credential.id, "queued", at, { "provider" => credential.provider,
      "credential_kind" => credential.kind } ] ], reads.pluck(:credential_id, :state, :requested_at, :params)
  end

  def account_email(length)
    local = "a" * 64
    domain = [ "b" * 63, "c" * 63, "d" * (length - 201), "invalid" ].join(".")
    "#{local}@#{domain}"
  end

  test "a plan and an account email go to the credential's row and nowhere else (IN-25)" do
    credential, request = adding
    plan = "p" * 40
    email = account_email(254)
    written = events_written do
      assert_completed(report(request, result_body(plan: plan, account_email: email), key: "with-email-key"))
    end

    credential.reload
    assert_equal [ plan, email ], [ credential.plan, credential.account_email ]
    assert written.none? { |event| event.attributes.to_json.include?(email) }
    assert written.none? { |event| event.attributes.to_json.include?(plan) }
    assert_nil request.reload.result.fetch("plan")
    assert_nil request.result.fetch("account_email")
    assert_not_includes request.reload.result.to_json, email
    assert_not_includes Command.find_by!(key: "with-email-key").attributes.to_json, email
    assert_not_includes Command.find_by!(key: "with-email-key").attributes.to_json, plan
  end

  test "an overlong plan or email is dropped without replacing either stored fact (CR-6)" do
    credential = @scenario.credential(provider: "codex", plan: "Made-up kept plan",
      account_email: "made-up.owner@example.invalid")
    request = queue_request("verify", credential: credential, state: "picked_up")
    plan = "p" * 41
    email = account_email(255)

    written = events_written { assert_completed(report(request, result_body(plan: plan, account_email: email))) }

    assert_equal [ "Made-up kept plan", "made-up.owner@example.invalid" ],
      [ credential.reload.plan, credential.account_email ]
    assert_equal [ "credential.verified" ], written.map(&:type)
    assert_equal({}, written.first.payload)
    assert_nil request.reload.result.fetch("plan")
    assert_nil request.result.fetch("account_email")
  end

  test "a null plan or email leaves the row's values as they are" do
    credential = @scenario.credential(provider: "codex", plan: "Made-up kept plan")
    request = queue_request("verify", credential: credential, state: "picked_up")

    assert_completed(report(request, result_body))

    assert_equal "Made-up kept plan", credential.reload.plan
  end

  test "a failed add deletes the row and writes no event" do
    credential, request = adding
    written = events_written do
      assert_completed(report(request, result_body(outcome: "failed", checks: login_checks(failed: "signed_in"))))
    end

    assert_empty written
    assert_not Credential.exists?(credential.id)
    assert_equal "failed", request.reload.state
  end

  test "an add reported finished with a failed check is a failed add" do
    credential, request = adding

    assert_completed(report(request, result_body(checks: login_checks(failed: "test_prompt", failure: "no_answer"))))

    assert_not Credential.exists?(credential.id)
  end

  test "an add with no checks reported is not an add whose checks passed" do
    credential, request = adding

    assert_completed(report(request, result_body(checks: [])))

    assert_not Credential.exists?(credential.id)
  end

  test "a verify whose checks pass writes credential.verified and makes the login active again" do
    credential = @scenario.credential(provider: "codex", state: "signed_out")
    request = queue_request("verify", credential: credential, state: "picked_up")
    written = events_written { assert_completed(report(request, result_body)) }

    assert_equal [ "credential.verified" ], written.map(&:type)
    assert_equal credential.id, written.first.subject_id
    credential.reload
    assert_equal "active", credential.state
    assert_equal written.first.at, credential.last_verified_at
  end

  test "a verify whose sign-in check fails writes credential.signed_out with no seat, review or job" do
    credential = @scenario.credential(provider: "codex")
    request = queue_request("verify", credential: credential, state: "picked_up")
    written = events_written do
      assert_completed(report(request, result_body(outcome: "failed", checks: login_checks(failed: "signed_in"))))
    end

    assert_equal [ "credential.signed_out" ], written.map(&:type)
    assert_equal({ "seat_id" => nil, "review_id" => nil, "job_id" => nil }, written.first.payload)
    assert_equal "signed_out", credential.reload.state
    assert Credential.exists?(credential.id), "a verify never deletes a credential"
  end

  test "a verify that fails another check writes no event and changes nothing on the row" do
    credential = @scenario.credential(provider: "codex")
    before = credential.reload.attributes.except("updated_at")
    request = queue_request("verify", credential: credential, state: "picked_up")
    written = events_written do
      assert_completed(report(request, result_body(outcome: "failed",
        checks: login_checks(failed: "test_prompt", failure: "timed_out"))))
    end

    assert_empty written
    assert_equal before, credential.reload.attributes.except("updated_at")
  end

  test "install, start and stop results are recorded and write no event" do
    seat = @scenario.seat(credential: @scenario.credential)
    requests = [
      queue_request("install_tool", state: "picked_up", params: { "provider" => "claude" }),
      queue_request("start_seat", seat: seat, state: "picked_up"),
      queue_request("stop_seat", seat: seat, state: "picked_up")
    ]

    written = events_written do
      requests.each { |request| assert_completed(report(request, result_body(checks: []))) }
    end

    assert_empty written
    assert_equal %w[finished finished finished], requests.map { |request| request.reload.state }
  end

  test "a read_usage result is stored and writes no event (CR-13)" do
    credential = @scenario.credential
    request = queue_request("read_usage", credential: credential, state: "picked_up",
      params: { "provider" => credential.provider, "credential_kind" => credential.kind })
    result = result_body(checks: [ check("reading_taken") ], tool_version: nil)

    written = events_written { assert_completed(report(request, result)) }

    assert_empty written
    assert_equal "finished", request.reload.state
    assert_equal result, request.result
    assert_not_nil request.finished_at
  end

  test "a result for a request marked failed by Remove completes and changes nothing" do
    credential = @scenario.credential
    request = queue_request("read_usage", credential: credential, state: "picked_up",
      params: { "provider" => credential.provider, "credential_kind" => credential.kind })
    HelperRequest.transaction(requires_new: true) do
      Leverage::CredentialUse.release(@scenario.context, credential)
      credential.delete
    end
    before = request.reload.attributes
    assert_equal [ "failed", nil ], before.values_at("state", "result")
    assert_not_nil before.fetch("finished_at")
    assert_not Credential.exists?(credential.id)

    written = events_written do
      assert_completed(report(request, result_body(checks: [ check("reading_taken") ], tool_version: nil)))
    end

    assert_empty written
    assert_equal before, request.reload.attributes
    assert_not Credential.exists?(credential.id)
  end

  test "a request already finished is invalid_state" do
    request = queue_request("install_tool", state: "finished", params: { "provider" => "claude" })

    assert_refused("invalid_state", report(request, result_body(checks: [])))
  end

  test "a request with no result must have the failed state, credential and finish time recorded by Remove" do
    credential = @scenario.credential
    no_credential = queue_request("install_tool", state: "failed")
    no_credential.update!(finished_at: @scenario.database_now)
    no_finish_time = queue_request("read_usage", credential: credential, state: "failed")
    finished = queue_request("read_usage", credential: credential, state: "finished")
    finished.update!(finished_at: @scenario.database_now)

    [ no_credential, no_finish_time, finished ].each do |request|
      assert_refused("invalid_state", report(request, result_body(checks: [])))
    end
  end

  test "a request that already reported a failure is invalid_state" do
    credential = @scenario.credential
    request = queue_request("read_usage", credential: credential, state: "picked_up",
      params: { "provider" => credential.provider, "credential_kind" => credential.kind })
    failed = result_body(outcome: "failed", checks: [ check("reading_taken", passed: false, failure: "timed_out") ],
      tool_version: nil)
    assert_completed(report(request, failed))
    before = request.reload.attributes
    assert_equal [ "failed", failed ], before.values_at("state", "result")

    written = events_written do
      assert_refused("invalid_state", report(request, result_body(checks: [ check("reading_taken") ], tool_version: nil)))
    end

    assert_empty written
    assert_equal before, request.reload.attributes
  end

  %w[rejected not_signed_in unreachable timed_out no_answer token_store_unavailable provider_mismatch].each do |failure|
    test "a token Verify that reports #{failure} has the TK-3 outcome" do
      credential = @scenario.token_credential
      request = queue_request("verify", credential: credential, state: "picked_up",
        params: { "provider" => credential.provider, "credential_kind" => credential.kind })
      before = credential.reload.attributes
      result = result_body(outcome: "failed", checks: [ check("token_works", passed: false, failure: failure) ],
        tool_version: nil)

      written = events_written { assert_completed(report(request, result)) }

      assert_equal [ "failed", result ], request.reload.attributes.values_at("state", "result")
      if %w[rejected not_signed_in].include?(failure)
        assert_equal [ "credential.signed_out" ], written.map(&:type)
        assert_equal credential.id, written.first.subject_id
        assert_equal({ "seat_id" => nil, "review_id" => nil, "job_id" => nil }, written.first.payload)
        assert_equal "signed_out", credential.reload.state
      else
        assert_empty written
        assert_equal before, credential.reload.attributes
      end
    end
  end

  test "a token Verify that reports a failed login check does not sign out the token" do
    credential = @scenario.token_credential
    request = queue_request("verify", credential: credential, state: "picked_up")
    result = result_body(outcome: "failed", checks: [ check("signed_in", passed: false, failure: "not_signed_in") ])

    assert_empty events_written { assert_completed(report(request, result)) }
    assert_equal "active", credential.reload.state
  end

  test "a request of another workspace is not found" do
    other = Scenario.new
    request = queue_request("install_tool", params: { "provider" => "claude" }, scenario: other)

    assert_raises(T::NotFound) { report(request, result_body(checks: [])) }
  end

  test "an unknown request is not found" do
    assert_raises(T::NotFound) do
      helper_command("report_request_result", { "id" => SecureRandom.uuid, "result" => result_body })
    end
  end

  # --- milestone 3 -----------------------------------------------------------------------

  def reevaluations(&block) = spy_on(Leverage::Handoff, :reevaluate, &block)

  def passed(kind, credential)
    request = queue_request(kind, credential: credential, state: "picked_up",
      params: { "provider" => credential.provider, "credential_kind" => "login" })
    calls = nil
    written = events_written { calls = reevaluations { assert_completed(report(request, result_body)) } }
    [ written, calls ]
  end

  test "a passed add looks at the open credential holds again, as caused by credential.added, and keeps its model" do
    credential, request = adding
    credential.update!(model: "tool-default-model")
    calls = nil
    written = events_written { calls = reevaluations { assert_completed(report(request, result_body)) } }

    assert_equal [ "credential.added" ], written.map(&:type)
    assert_equal [ { cause: written.first, verified: credential.reload } ], calls.map(&:keywords)
    assert_equal "tool-default-model", credential.model
  end

  test "a failed add looks at nothing" do
    _credential, request = adding
    calls = reevaluations do
      assert_completed(report(request, result_body(outcome: "failed", checks: login_checks(failed: "signed_in"))))
    end

    assert_empty calls
  end

  test "a passed Verify looks at the open credential holds again, with no choice" do
    credential = @scenario.credential(provider: "codex", state: "signed_out")
    written, calls = passed("verify", credential)

    assert_equal [ "credential.verified" ], written.map(&:type)
    assert_equal [ { cause: written.first, verified: credential.reload } ], calls.map(&:keywords)
  end

  test "a passed Verify clears a limit with no reset time (HE-2)" do
    credential = @scenario.limit_credential(@scenario.credential(provider: "codex"))
    assert credential.limited?(@scenario.database_now)

    passed("verify", credential)

    credential.reload
    assert_equal [ nil, nil, "active" ], [ credential.limited_since, credential.limited_until, credential.state ]
  end

  test "a passed Verify leaves a limit with a reset time alone: the account rests until then (HE-2, L661)" do
    reset = @scenario.database_now + 3600
    credential = @scenario.limit_credential(@scenario.credential(provider: "codex"), reset_at: reset)
    since = credential.limited_since

    passed("verify", credential)

    credential.reload
    assert_equal [ since.to_i, reset.to_i ], [ credential.limited_since.to_i, credential.limited_until.to_i ]
  end

  test "a passed Sign in again verifies the login, clears a limit with no reset time and answers with the choice sign_in_again" do
    credential = @scenario.limit_credential(@scenario.credential(provider: "claude"))
    credential.update!(state: "signed_out")
    written, calls = passed("open_sign_in", credential)

    assert_equal [ "credential.verified" ], written.map(&:type)
    assert_equal [ "credential", credential.id, "app", @scenario.helper.id ],
      [ written.first.subject_kind, written.first.subject_id, written.first.actor_kind, written.first.actor_id ]
    credential.reload
    assert_equal [ "active", nil ], [ credential.state, credential.limited_since ]
    assert_equal written.first.at, credential.last_verified_at
    assert_equal [ { cause: written.first, verified: credential, choice: "sign_in_again" } ], calls.map(&:keywords)
  end

  test "a Sign in again whose sign-in check fails writes credential.signed_out with no seat and looks at the holds again" do
    credential = @scenario.credential(provider: "claude")
    request = queue_request("open_sign_in", credential: credential, state: "picked_up",
      params: { "provider" => "claude", "credential_kind" => "login" })
    calls = nil
    written = events_written do
      calls = reevaluations do
        assert_completed(report(request, result_body(outcome: "failed", checks: login_checks(failed: "signed_in"))))
      end
    end

    assert_equal [ "credential.signed_out" ], written.map(&:type)
    assert_equal({ "seat_id" => nil, "review_id" => nil, "job_id" => nil }, written.first.payload)
    assert_equal "signed_out", credential.reload.state
    assert_equal [ { cause: written.first, signed_out: credential } ], calls.map(&:keywords)
  end

  test "a Verify that finds the login signed out looks at the holds again for HE-11" do
    credential = @scenario.credential(provider: "codex")
    request = queue_request("verify", credential: credential, state: "picked_up")
    calls = nil
    written = events_written do
      calls = reevaluations do
        assert_completed(report(request, result_body(outcome: "failed", checks: login_checks(failed: "signed_in"))))
      end
    end

    assert_equal [ { cause: written.first, signed_out: credential.reload } ], calls.map(&:keywords)
  end

  test "a Sign in again that fails another check writes nothing and looks at nothing" do
    credential = @scenario.limit_credential(@scenario.credential(provider: "claude"))
    before = credential.reload.attributes.except("updated_at")
    request = queue_request("open_sign_in", credential: credential, state: "picked_up")
    calls = nil
    written = events_written do
      calls = reevaluations do
        assert_completed(report(request, result_body(outcome: "failed",
          checks: login_checks(failed: "test_prompt", failure: "timed_out"))))
      end
    end

    assert_equal [ [], [] ], [ written, calls ]
    assert_equal before, credential.reload.attributes.except("updated_at")
    assert_equal "failed", request.reload.state
  end
end
