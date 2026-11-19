# events and rule_versions accept inserts only (PRD, Data model and Event
# log; C1, C14, C22, DB-7). Triggers refuse UPDATE, DELETE and TRUNCATE for
# every role, the superuser included, and pg_dump keeps them in
# db/structure.sql, which grants would not survive. The leverage_app role
# (db:grants) also lacks those privileges.
class AddAppendOnlyTriggers < ActiveRecord::Migration[8.1]
  APPEND_ONLY = %w[events rule_versions].freeze

  def up
    execute <<~SQL
      CREATE FUNCTION leverage_refuse_change() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION '% is append-only: % is not allowed', TG_TABLE_NAME, TG_OP
          USING ERRCODE = 'restrict_violation';
      END;
      $$;
    SQL

    APPEND_ONLY.each do |table|
      execute <<~SQL
        CREATE TRIGGER #{table}_append_only
          BEFORE UPDATE OR DELETE ON #{table}
          FOR EACH ROW EXECUTE FUNCTION leverage_refuse_change();

        CREATE TRIGGER #{table}_no_truncate
          BEFORE TRUNCATE ON #{table}
          FOR EACH STATEMENT EXECUTE FUNCTION leverage_refuse_change();
      SQL
    end
  end

  def down
    APPEND_ONLY.each do |table|
      execute <<~SQL
        DROP TRIGGER #{table}_no_truncate ON #{table};
        DROP TRIGGER #{table}_append_only ON #{table};
      SQL
    end
    execute "DROP FUNCTION leverage_refuse_change();"
  end
end
