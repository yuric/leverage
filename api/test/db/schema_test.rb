require "test_helper"
require_relative "expected_schema"
require_relative "rows"

# The database built from db/structure.sql against ExpectedSchema: tables,
# columns, indexes, unique constraints and foreign keys, and the rules the
# PRD's Data model states about every table.
class SchemaTest < ActiveSupport::TestCase
  include DbRows

  ON_DELETE = { "a" => :restrict, "r" => :restrict, "c" => :cascade, "n" => :nullify, "d" => :default }.freeze
  INDEX_DEF = /\ACREATE (UNIQUE )?INDEX \S+ ON public\.\S+ USING btree \((.+?)\)( NULLS NOT DISTINCT)?(?: WHERE (.+))?\z/

  def public_tables
    sql(<<~SQL).rows.flatten - ExpectedSchema::RAILS_TABLES
      SELECT table_name FROM information_schema.tables
      WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
    SQL
  end

  def columns_of(table)
    sql(<<~SQL, table).rows.to_h { |name, type, not_null, default| [ name, [ type, !not_null, default ] ] }
      SELECT a.attname, format_type(a.atttypid, a.atttypmod), a.attnotnull, pg_get_expr(d.adbin, d.adrelid)
      FROM pg_attribute a
      LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
      WHERE a.attrelid = ('public.' || $1)::regclass AND a.attnum > 0 AND NOT a.attisdropped
    SQL
  end

  def indexes_of(table)
    sql(<<~SQL, table).rows.flatten.map { |definition| parse_index(definition) }
      SELECT pg_get_indexdef(i.indexrelid) FROM pg_index i
      WHERE i.indrelid = ('public.' || $1)::regclass AND NOT i.indisprimary
    SQL
  end

  def parse_index(definition)
    match = INDEX_DEF.match(definition) or flunk("unexpected index form: #{definition}")
    [ match[2].delete('"').split(", ").freeze, !match[1].nil?, match[4], !match[3].nil? ]
  end

  def foreign_keys_of(table)
    sql(<<~SQL, table).rows.map { |column, target, action| [ column, target, ON_DELETE.fetch(action) ] }
      SELECT a.attname, c.confrelid::regclass::text, c.confdeltype
      FROM pg_constraint c
      JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
      WHERE c.contype = 'f' AND c.conrelid = ('public.' || $1)::regclass
    SQL
  end

  def primary_key_of(table)
    sql(<<~SQL, table).rows.flatten
      SELECT a.attname FROM pg_constraint c
      JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = ANY (c.conkey)
      WHERE c.contype = 'p' AND c.conrelid = ('public.' || $1)::regclass
    SQL
  end

  test "the database has exactly the tables of the Data model and the three the plan adds" do
    assert_equal ExpectedSchema::TABLES.keys.sort, public_tables.sort
    assert_equal 29, ExpectedSchema::TABLES.size
  end

  ExpectedSchema::TABLES.each do |table, expected|
    test "#{table} has its columns with their types, null-ability and defaults" do
      assert_equal expected[:columns].sort.to_h, columns_of(table).sort.to_h
    end

    test "#{table} has its indexes and unique constraints" do
      assert_equal expected[:indexes].map(&:to_a).sort_by(&:inspect), indexes_of(table).sort_by(&:inspect)
    end

    test "#{table} has its foreign keys and a uuid primary key" do
      assert_equal expected[:foreign_keys].map(&:to_a).sort, foreign_keys_of(table).sort
      assert_equal [ "id" ], primary_key_of(table)
    end
  end

  test "the credential position is unique per workspace as a deferrable constraint" do
    deferrable = sql(<<~SQL).rows
      SELECT conrelid::regclass::text, condeferrable, condeferred,
             ARRAY(SELECT attname FROM pg_attribute WHERE attrelid = conrelid AND attnum = ANY (conkey) ORDER BY attname)::text
      FROM pg_constraint WHERE contype = 'u' AND condeferrable
    SQL
    assert_equal [ [ "credentials", true, true, "{position,workspace_id}" ] ], deferrable
  end

  test "every table but workspaces has workspace_id uuid not null with a foreign key (C8)" do
    public_tables.without("workspaces").each do |table|
      assert_equal [ "uuid", false, nil ], columns_of(table)["workspace_id"], table
      assert_includes foreign_keys_of(table), [ "workspace_id", "workspaces", :restrict ], table
    end
  end

  test "no column name could hold a secret, except the hashes (C20, C23)" do
    names = public_tables.flat_map { |table| columns_of(table).keys.map { |column| "#{table}.#{column}" } }
    suspicious = names.select { |name| name.split(".").last.match?(ExpectedSchema::SECRET_WORD) }
    allowed = suspicious.select { |name| ExpectedSchema::ALLOWED_SECRET_NAMES.include?(name.split(".").last) }
    assert_equal [], suspicious - allowed
    assert_equal %w[helpers.token_hash seats.token_hash sessions.token_hash users.password_digest], allowed.sort
  end

  test "no column name is one Active Record reserves" do
    public_tables.each do |table|
      columns_of(table).each_key do |column|
        refute ActiveRecord::Base.dangerous_attribute_method?(column), "#{table}.#{column}"
      end
    end
  end

  test "every due-time source the registry names is an existing timestamp column (TM-1)" do
    Leverage::Contract.registry.fetch("due_time_sources").each do |source|
      table, column = source.split(".")
      assert_equal ExpectedSchema::TZ, columns_of(table).dig(column, 0), source
    end
  end

  test "inbox items store their choices and facts (DB-33)" do
    columns = columns_of("inbox_items")
    assert_equal [ "jsonb", false, nil ], columns["choices"]
    assert_equal [ "jsonb", false, nil ], columns["facts"]
  end

  test "no PostgreSQL enum type exists; values are text checked against the registry (DB-47)" do
    assert_equal 0, sql("SELECT count(*) FROM pg_type WHERE typtype = 'e'").rows.first.first
  end

  test "every value a partial index or a default names is in its registry list" do
    registry = Leverage::Contract.registry
    ExpectedSchema::INDEX_VALUES.each do |where, (value, list)|
      values = case list
      when :credential_providers then registry.fetch("credential_providers").map { |entry| entry.fetch("provider") }
      when Symbol then registry.fetch(list.to_s)
      else registry.fetch("lists").fetch(list)
      end
      assert_includes values, value, where
    end
  end

  test "helper requests have no token column and refuse a result holding a token (IF-15)" do
    assert_empty columns_of("helper_requests").keys.grep(/token/)
    request = ->(result) { insert("helper_requests", workspace_id: workspace, kind: "start_seat", requested_at: Time.current, result: result) }
    assert_rejected { request.call({ "token" => "made-up" }) }
    assert_rejected { request.call({ "seat_token" => "made-up" }) }
    assert_rejected { request.call({ "seat" => { "token" => "made-up" } }) }
    assert_rejected { request.call([ { "seat_token" => "made-up" } ]) }
    assert_accepted { request.call({ "checks" => [ { "name" => "signed_in", "passed" => true } ], "tokens" => 12 }) }
    assert_accepted { request.call(nil) }
  end

  test "stored command outcomes refuse a result holding a token (IF-15)" do
    command = ->(result) {
      insert("commands", workspace_id: workspace, caller_kind: "helper", caller_id: SecureRandom.uuid,
        key: SecureRandom.uuid, command: "issue_seat_token", request_hash: "made-up", outcome: "completed", result: result)
    }
    assert_rejected { command.call({ "seat_token" => "made-up" }) }
    assert_rejected { command.call({ "token" => "made-up" }) }
    assert_accepted { command.call({ "seat_id" => SecureRandom.uuid }) }
  end
end
