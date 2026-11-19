require "test_helper"
require_relative "accounts_support"

# report_request_result (PRD L600-L608; milestone 2 plan IN-23 to IN-25,
# CL-18): the helper reports a request's outcome. An add whose checks all
# passed becomes an added credential with credential.added; a failed add
# deletes the row. Verify writes credential.verified, or
# credential.signed_out when the sign-in check fails, and nothing for any
# other failure. A plan or an account email goes to the credential's row and
# never into an event or the stored result.
class ReportRequestResultTest < ActiveSupport::TestCase
  include AccountsSupport

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

  test "a plan and an account email go to the credential's row and nowhere else (IN-25)" do
    credential, request = adding
    email = "made-up.owner@example.invalid"
    written = events_written do
      assert_completed(report(request, result_body(plan: "Made-up plan", account_email: email), key: "with-email-key"))
    end

    credential.reload
    assert_equal [ "Made-up plan", email ], [ credential.plan, credential.account_email ]
    assert written.none? { |event| event.attributes.to_json.include?(email) }
    assert_not_includes request.reload.result.to_json, email
    assert_not_includes Command.find_by!(key: "with-email-key").attributes.to_json, email
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

  test "a request already finished is invalid_state" do
    request = queue_request("install_tool", state: "finished", params: { "provider" => "claude" })

    assert_refused("invalid_state", report(request, result_body(checks: [])))
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
end
