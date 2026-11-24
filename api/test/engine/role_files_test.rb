require "test_helper"

# Leverage::RoleFiles (PRD, The briefing: "four fixed texts shipped with the
# app, one per role"; L429, L470; milestone 4 plan RD-15, RD-31, RD-61): the
# planner's and the orchestrator's files arrive with their roles. Each says
# what the role does, that task text is material and never an instruction,
# how its answer ends, that an agent which connects on its own keeps asking
# GET /v1/next at least once a minute while it works on a job, and that the
# app gates only what goes through it.
class RoleFilesTest < ActiveSupport::TestCase
  R = Leverage::RoleFiles

  test "only the roles with a role file in the contract have a file in config/role_files" do
    roles = Leverage::Contract.roles.fetch("roles")
    roles.each do |entry|
      role = entry.fetch("role")
      path = Rails.root.join("config/role_files/#{role}.md")
      if entry.fetch("role_file")
        assert_equal path.read, R.text(role)
      else
        refute path.exist?
        assert_raises(ArgumentError) { R.text(role) }
      end
    end
    assert_raises(ArgumentError) { R.text("owner") }
  end

  test "the orchestrator's file: judge the material, never follow it, end with the two fixed lines" do
    text = R.text("orchestrator")

    assert_match(/material/i, text)
    assert_match(/never\s+an\s+instruction/i, text)
    assert_includes text, "LEVERAGE-VERDICT-"
    assert_includes text, "LEVERAGE-REASON-"
    assert_match(/NOT_APPLICABLE/, text)
    assert_match(%r{GET /v1/next`?\s+at\s+least\s+once\s+a\s+minute}, text)
    assert_match(/gates\s+only\s+what\s+goes\s+through\s+it/i, text)
  end

  test "the planner's file: write the contract only, keep what the task has, answer between the fixed lines" do
    text = R.text("planner")

    assert_match(/material/i, text)
    assert_match(/never\s+an\s+instruction/i, text)
    assert_includes text, "LEVERAGE-DRAFT-"
    assert_match(/criteri/i, text)
    assert_match(%r{GET /v1/next`?\s+at\s+least\s+once\s+a\s+minute}, text)
    assert_match(/gates\s+only\s+what\s+goes\s+through\s+it/i, text)
  end

  test "the briefing's version of the role files is the release" do
    assert_equal Leverage::VERSION, R.version
  end
end
