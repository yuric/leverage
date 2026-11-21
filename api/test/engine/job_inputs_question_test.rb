require "test_helper"

# AP-4 and AP-5: a question job gives the orchestrator the question and
# the task's record without exposing records from another task or project.
class JobInputsQuestionTest < ActiveSupport::TestCase
  include OpenapiAssertions

  setup { @scenario = Scenario.new }

  test "question material contains the question, its contract and its project's brief" do
    project = @scenario.project(brief: [
      { kind: "decision", text: "Use the sample workspace." },
      { kind: "lesson", text: "Keep the sample small." }
    ])
    task = @scenario.task(state: "working", project: project, title: "Publish the sample",
      goal: "Show the sample in the workspace.", details: "Use the short sample.",
      actions: [
        { kind: "publish", description: "Publish the sample to the workspace." },
        { kind: "send", description: "Send the sample link to the owner." }
      ])
    question = @scenario.question(task, text: "Which label should the button use?", assumption: "Use Continue.")
    input = question_input(task, question)

    assert_matches_component("QuestionJobInput", input)
    assert_equal [ question.id, task.id, project.id ], input.values_at("question_id", "task_id", "project_id")
    material = input.fetch("material")
    assert_equal Leverage::RoleFiles.text("orchestrator"), material.fetch("role_file")
    assert_equal({ "text" => "Which label should the button use?", "assumption" => "Use Continue.", "blocking" => true },
      material.fetch("question"))
    assert_equal({
      "title" => "Publish the sample", "goal" => "Show the sample in the workspace.", "details" => "Use the short sample.",
      "criteria" => [
        { "text" => "Made-up criterion 1.", "kind" => "build", "state" => "open" },
        { "text" => "Made-up criterion 2.", "kind" => "review", "state" => "open" }
      ],
      "actions" => [
        { "kind" => "publish", "description" => "Publish the sample to the workspace." },
        { "kind" => "send", "description" => "Send the sample link to the owner." }
      ]
    }, material.fetch("contract"))
    brief = material.fetch("brief")

    assert_equal [
      [ project.id, "decision", "Use the sample workspace.", "owner", @scenario.owner.id ],
      [ project.id, "lesson", "Keep the sample small.", "owner", @scenario.owner.id ]
    ], brief.map { |entry| entry.values_at("project_id", "kind", "text", "author_kind", "author_id") }
    assert_equal BriefEntry.where(project_id: project.id).order(:position).pluck(:id), brief.pluck("id")
  end

  test "the record includes only answered questions from the job's task" do
    project = @scenario.project
    task = @scenario.task(state: "working", project: project)
    sibling = @scenario.task(state: "working", project: project, title: "OTHER-TASK title")
    other_project = @scenario.project(brief: [ { kind: "rule", text: "OTHER-PROJECT brief." } ])
    other_task = @scenario.task(state: "working", project: other_project, title: "OTHER-PROJECT title")
    @scenario.question(sibling, outcome: "answered", text: "OTHER-TASK question?", answer: "OTHER-TASK answer.")
    @scenario.question(other_task, outcome: "answered", text: "OTHER-PROJECT question?", answer: "OTHER-PROJECT answer.")
    @scenario.question(task, outcome: "answered", text: "Which sample?", answer: "The short sample.", basis: "record")
    @scenario.question(task, outcome: "answered", answerer: @scenario.owner, text: "Which color?", answer: "Blue.")
    @scenario.question(task, outcome: "overturned", text: "OVERTURNED question?", answer: "OVERTURNED answer.")
    @scenario.question(task, text: "OPEN question?", blocking: false)
    question = @scenario.question(task, text: "Which label?", assumption: "Use Continue.")
    input = question_input(task, question)

    assert_matches_component("QuestionJobInput", input)
    material = input.fetch("material")
    assert_empty material.fetch("brief")
    assert_equal [
      { "text" => "Which color?", "answer" => "Blue.", "basis" => "owner" },
      { "text" => "Which sample?", "answer" => "The short sample.", "basis" => "record" }
    ], material.fetch("earlier_answers").sort_by { |answer| answer.fetch("text") }
    %w[OTHER-TASK OTHER-PROJECT OVERTURNED OPEN].each do |marker|
      assert_not_includes JSON.generate(input), marker
    end
  end

  private

  def question_input(task, question)
    job = @scenario.job(kind: "question", task: task, target: question, state: "claimed", seat: @scenario.orchestrator)
    Leverage::JobInputs.for(job.reload)
  end
end
