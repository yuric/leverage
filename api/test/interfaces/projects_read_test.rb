require "test_helper"

# The projects screen reads the brief as one ordered list (AP-26, AP-27).
class ProjectsReadTest < CommittingTestCase
  include OpenapiAssertions

  test "list projects includes its own ordered brief and counts only open tasks of that project" do
    project = scenario.project(name: "Sample project", goal: "Collect sample results.", budget: 24.25,
      brief: [ { kind: "lesson", text: "Put the samples first." }, { kind: "rule", text: "Use whole numbers." } ])
    quiet = scenario.project(name: "Another sample project")
    %w[backlog working done cancelled].each { |state| scenario.task(state: state, project: project) }
    scenario.task(state: "working")
    Scenario.new.project

    rows = projects
    assert_equal [ project.id, quiet.id ].sort, rows.map { |row| row.fetch("id") }.sort
    row = rows.find { |item| item["id"] == project.id }
    assert_equal [ project.name, project.goal, 24.25, 2, nil, nil ],
      row.values_at("name", "goal", "budget", "open_tasks", "paused_by", "content_deleted_at")
    assert_equal [ [ "lesson", "Put the samples first." ], [ "rule", "Use whole numbers." ] ],
      row.fetch("brief").map { |entry| entry.values_at("kind", "text") }
    assert_equal [ [ project.id, "owner", scenario.owner.id ] ] * 2,
      row.fetch("brief").map { |entry| entry.values_at("project_id", "author_kind", "author_id") }
    assert_empty rows.find { |item| item["id"] == quiet.id }.fetch("brief")
  end

  test "paused_by follows the latest pause of each project and clears on resumption" do
    project = scenario.project
    budget = scenario.project
    pause(project, actor_kind: "owner", actor_id: scenario.owner.id)
    pause(budget, actor_kind: "app")

    rows = projects.index_by { |row| row.fetch("id") }
    assert rows.key?(project.id), "the owner-paused project is listed"
    assert rows.key?(budget.id), "the budget-paused project is listed"
    assert_equal [ true, "owner" ], rows.fetch(project.id).values_at("paused", "paused_by")
    assert_equal [ true, "budget" ], rows.fetch(budget.id).values_at("paused", "paused_by")

    project.update!(paused: false)
    scenario.append("project.resumed", project_id: project.id, actor_kind: "owner", actor_id: scenario.owner.id)
    row = projects.find { |item| item["id"] == project.id }
    assert row, "the resumed project is listed"
    assert_equal [ false, nil ], row.values_at("paused", "paused_by")
  end

  test "latest work reference comes from the newest task with a reference and present content" do
    project = scenario.project
    other = scenario.project
    empty = scenario.project
    at = Time.current - 1.day
    lower_id, higher_id = Array.new(2) { SecureRandom.uuid }.sort
    old = scenario.task(project: project, work_reference: "~/old")
    old.update!(created_at: at - 1.hour)
    higher = scenario.task(project: project, work_reference: "~/latest", id: higher_id)
    higher.update!(created_at: at)
    lower = scenario.task(project: project, work_reference: "~/same-time", id: lower_id)
    lower.update!(created_at: at)
    scenario.task(project: project, work_reference: "")
    scenario.task(project: project, work_reference: nil)
    deleted = scenario.task(project: project, work_reference: "~/deleted")
    deleted.update!(content_deleted_at: Time.current)
    scenario.task(project: other, work_reference: "~/other")
    scenario.task(project: empty, work_reference: nil)
    old.touch

    rows = projects.index_by { |row| row.fetch("id") }
    assert_equal "~/latest", rows.fetch(project.id).fetch("latest_work_reference")
    assert_equal "~/other", rows.fetch(other.id).fetch("latest_work_reference")
    assert_nil rows.fetch(empty.id).fetch("latest_work_reference")
  end

  private

  def projects
    body = JSON.parse(JSON.generate(Leverage::Reads::Projects.call(scenario.workspace_id)))
    assert_empty contract_errors("#/components/schemas/ProjectsList", body)
    body.fetch("projects")
  end

  def pause(project, actor_kind:, actor_id: nil)
    project.update!(paused: true)
    scenario.append("project.paused", project_id: project.id, actor_kind: actor_kind, actor_id: actor_id)
  end
end
