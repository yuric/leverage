require "test_helper"

class UsageReadsTest < ActiveSupport::TestCase
  Reads = Leverage::UsageReads

  setup do
    @scenario = Scenario.new
    @at = @scenario.database_now
    @scenario.live_helper(at: @at - 90.seconds)
  end

  test "a helper's report is live for ninety seconds in its own workspace" do
    assert Reads.helper_alive?(@at, workspace_id: @scenario.workspace_id)
    refute Reads.helper_alive?(@at + 1.second, workspace_id: @scenario.workspace_id)
    refute Reads.helper_alive?(@at, workspace_id: Scenario.new.workspace_id)
  end

  test "due includes active logins and tokens without a reading or with one stored over nine minutes ago" do
    missing = @scenario.credential
    old = @scenario.token_credential
    @scenario.reading(old, observed_at: @at, created_at: @at - 570.seconds)

    assert_equal [ missing.id, old.id ], due_ids
  end

  test "due uses storage time and excludes readings stored exactly nine minutes ago or more recently" do
    [ 510, 540 ].each do |age|
      credential = @scenario.credential
      @scenario.reading(credential, observed_at: @at - 900.seconds, created_at: @at - age.seconds)
    end

    assert_empty due_ids
  end

  test "due excludes an account with a recent stored reading even if its previous reading was observed later" do
    credential = @scenario.credential
    @scenario.reading(credential, observed_at: @at - 5.seconds, created_at: @at - 570.seconds)
    @scenario.reading(credential, observed_at: @at - 10.seconds, created_at: @at - 510.seconds)

    assert_empty due_ids
  end

  test "due excludes signed-out and not yet added credentials and another workspace's rows" do
    @scenario.credential(state: "signed_out")
    @scenario.credential(added: false, state: "active")
    Scenario.new.credential

    assert_empty due_ids
  end

  test "due queues nothing for an overdue helper" do
    @scenario.credential
    @scenario.live_helper(at: @at - 91.seconds)

    assert_empty due_ids
  end

  test "only queued or picked-up usage reads keep an otherwise due account off the list" do
    %w[queued picked_up].each do |state|
      @scenario.helper_request(credential: @scenario.credential, kind: "read_usage", state: state)
    end
    finished = @scenario.credential
    @scenario.helper_request(credential: finished, kind: "read_usage", state: "finished")
    @scenario.helper_request(credential: finished, kind: "verify")

    assert_equal [ finished.id ], due_ids
  end

  test "one sweep selects at most fifty due accounts" do
    accounts = Array.new(51) { @scenario.credential }
    assert_equal accounts.first(50).map(&:id), due_ids
  end

  test "queue uses provider and credential kind only and reuses unfinished ids" do
    login = @scenario.credential
    token = @scenario.token_credential
    existing = @scenario.helper_request(credential: login, kind: "read_usage", state: "picked_up")

    ctx = @scenario.context
    ids = Reads.queue(ctx, [ login, token, token ])

    assert_equal 2, ids.size
    assert_equal existing.id, ids.first
    queued = HelperRequest.find(ids.last)
    assert_equal [ @scenario.workspace_id, token.id, "queued", "read_usage", ctx.at ],
      queued.attributes.values_at("workspace_id", "credential_id", "state", "kind", "requested_at")
    assert_equal({ "provider" => token.provider, "credential_kind" => token.kind }, queued.params)
    assert_equal ids, Reads.queue(ctx, [ login, token ])
    assert_equal 2, HelperRequest.where(workspace_id: @scenario.workspace_id, kind: "read_usage").count
  end

  test "purge removes only ended usage reads over seven days old in the workspace" do
    credential = @scenario.credential
    old = %w[finished failed].map do |state|
      @scenario.helper_request(credential: credential, kind: "read_usage", state: state, at: @at - 8.days)
    end
    recent = @scenario.helper_request(credential: credential, kind: "read_usage", state: "finished", at: @at - 6.days)
    boundary = @scenario.helper_request(credential: credential, kind: "read_usage", state: "finished", at: @at - 7.days)
    queued = @scenario.helper_request(credential: credential, kind: "read_usage", at: @at - 8.days)
    verify = @scenario.helper_request(credential: credential, kind: "verify", state: "finished", at: @at - 8.days)
    foreign = Scenario.new
    foreign_request = foreign.helper_request(credential: foreign.credential, kind: "read_usage", state: "finished", at: @at - 8.days)

    Reads.purge(@at, workspace_id: @scenario.workspace_id)

    assert_empty HelperRequest.where(id: old.map(&:id))
    assert_equal [ recent, boundary, queued, verify, foreign_request ].map(&:id).sort,
      HelperRequest.where(id: [ recent, boundary, queued, verify, foreign_request ].map(&:id)).order(:id).pluck(:id)
  end

  test "newest reading is the newest observation, with storage time breaking observation ties" do
    credential = @scenario.credential
    @scenario.reading(credential, observed_at: @at - 1.second, created_at: @at)
    @scenario.reading(credential, observed_at: @at, created_at: @at - 1.second)
    newest = @scenario.reading(credential, observed_at: @at, created_at: @at)
    @scenario.reading(@scenario.credential, observed_at: @at + 1.second)

    assert_equal newest, CredentialReading.newest_for(credential).first
  end

  private

  def due_ids = Reads.due(@at, workspace_id: @scenario.workspace_id).map(&:id)
end
