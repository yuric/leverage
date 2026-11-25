require "test_helper"

# DB-53 added the Imaginarium project's project.created to create_owner. The
# event log is append-only, so a workspace signed up before DB-53 holds a
# create_owner that wrote only the shipped rules' rule.created, and got its
# Imaginarium project later from install_imaginarium_project at startup. The
# log audit behind leverage:verify_log has to accept that sign-up as written.
class PreImaginariumSignUpAuditTest < ActionDispatch::IntegrationTest
  setup do
    Session.delete_all
    User.delete_all
  end

  def sign_up
    payload = { "email_address" => "owner@example.test", "password" => "made-up-password-1" }
    post "/v1/owner/setup", params: JSON.generate(payload),
      headers: { "Content-Type" => "application/json", "Idempotency-Key" => "setup-1" }
    assert_response :ok
    Workspace.find(User.sole.workspace_id)
  end

  # A sign-up as code before DB-53 ran it: create_owner wrote the shipped
  # rules' rule.created and created no Imaginarium project.
  def sign_up_before_db53
    original = Leverage::Projects.method(:create_imaginarium)
    Leverage::Projects.define_singleton_method(:create_imaginarium) { |*| nil }
    workspace = begin
      sign_up
    ensure
      Leverage::Projects.define_singleton_method(:create_imaginarium, original)
    end
    assert_nil workspace.imaginarium_project_id
    assert_empty Event.where(workspace_id: workspace.id, type: "project.created")
    workspace
  end

  test "a sign-up logged before DB-53, then the startup install, passes the audit" do
    workspace = sign_up_before_db53
    outcome = Leverage::Timers.apply_workspace(workspace.reload, "install_imaginarium_project", at: Time.current)
    assert outcome.completed?

    assert_empty Leverage::Replay.diff(workspace.id), "the replay of the log"
    assert_empty Leverage::LogAudit.call(workspace.id), "the log audit, sign-up included"
  end

  test "a sign-up logged today, with its project.created, still passes the audit" do
    workspace = sign_up
    assert_empty Leverage::LogAudit.call(workspace.id)
  end
end
