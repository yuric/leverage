# Raw SQL helpers for the database tests: they insert the smallest valid
# rows, with no model classes (none exist in this milestone). Every value is
# made up. A task is always inserted together with an event for it, because
# the state trigger (C7) rejects a task without one at commit, and
# test_helper fires deferred constraints before every rollback.
module DbRows
  # The workspace is made first, outside any savepoint a test opens, so that
  # a savepoint rolled back never takes it away.
  def self.included(test_class)
    test_class.setup { workspace }
  end

  def db
    ActiveRecord::Base.lease_connection
  end

  def sql(statement, *binds)
    db.exec_query(statement, "SQL", binds)
  end

  # Inserts a row and returns its id. Values are passed as bind parameters;
  # Arrays and Hashes are stored as jsonb unless the column is an array.
  def insert(table, values)
    columns = values.keys
    placeholders = columns.each_index.map { |i| "$#{i + 1}" }
    binds = values.values.map { |value| value.is_a?(Hash) || value.is_a?(Array) ? value.to_json : value }
    target = columns.empty? ? "DEFAULT VALUES" :
      "(#{columns.map { |c| db.quote_column_name(c) }.join(", ")}) VALUES (#{placeholders.join(", ")})"
    sql("INSERT INTO #{db.quote_table_name(table)} #{target} RETURNING id", *binds).rows.first.first
  end

  # Runs a statement in a savepoint, so a statement that fails leaves the
  # test's transaction usable. Returns the error raised, or nil.
  def in_savepoint
    db.transaction(requires_new: true) { yield }
    nil
  rescue ActiveRecord::StatementInvalid => error
    error
  end

  def assert_rejected(error_class = ActiveRecord::StatementInvalid, &block)
    error = in_savepoint(&block)
    assert_kind_of error_class, error, "expected the database to reject the statement"
    error
  end

  def assert_accepted(&block)
    error = in_savepoint(&block)
    assert_nil error, -> { "expected the statement to pass, got #{error&.message}" }
  end

  def workspace
    @workspace ||= insert("workspaces", {})
  end

  def user
    @user ||= insert("users", workspace_id: workspace, email_address: "owner-#{SecureRandom.hex(4)}@example.test",
      password_digest: "made-up-digest")
  end

  def seat(**values)
    insert("seats", { workspace_id: workspace, name: "seat #{SecureRandom.hex(3)}", provider: "claude",
      model: "made-up-model", effort: "medium", role: "builder", strength_rank: 1 }.merge(values))
  end

  def credential(**values)
    @positions = (@positions || 0) + 1
    insert("credentials", { workspace_id: workspace, kind: "login", provider: "claude",
      name: "account #{@positions}", position: @positions }.merge(values))
  end

  def next_seq
    @seq = (@seq || 0) + 1
  end

  # An event row, and the workspace's last_seq moved to its seq as
  # EventLog.append moves it: rows a test commits stay in the worker's
  # database, and the app must be able to append after them.
  def event(type: "task.created", task_id: nil, **values)
    defaults = { workspace_id: workspace, seq: next_seq, at: Time.current, effective_at: Time.current,
      type: type, schema_version: 1, actor_kind: "app", task_id: task_id, round: task_id && 0, payload: {} }
    row = defaults.merge(values)
    insert("events", row).tap do
      sql("UPDATE workspaces SET last_seq = GREATEST(last_seq, $1) WHERE id = $2", row[:seq], row[:workspace_id])
    end
  end

  # A task and its task.created event, in the current transaction.
  def task(**values)
    id = insert("tasks", { workspace_id: workspace, state: "backlog" }.merge(values))
    event(task_id: id)
    id
  end

  # A rule and its version 1: a rule's current version must exist by commit.
  def rule
    @rule ||= insert("rules", workspace_id: workspace, key: "made_up_rule", enabled: true, current_version: 1)
                .tap { |id| rule_version_of(id) }
  end

  def rule_version
    rule
    @rule_version
  end

  def rule_version_of(rule_id)
    @rule_version ||= insert("rule_versions", workspace_id: workspace, rule_id: rule_id, version: 1,
      key: "made_up_rule", name: "A made-up rule", hook: "task.before_ready", scope_kind: "all_tasks",
      kind: "gate", checker: "app", origin: "custom", author_kind: "owner")
  end
end
