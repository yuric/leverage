require "test_helper"

# The two lines of milestone 2 plan §2.1 a static test holds: only
# lib/leverage/event_log.rb inserts into events (PRD L215), and no file
# under app/controllers/ or lib/leverage/reads/ calls a writing Active
# Record method or sends writing SQL. Milestone 4 adds a third (its plan
# §2, RE-1): no file under lib/leverage/rules/ does either, because
# Leverage::Gating decides and the transition function writes. Comments
# are not code and are skipped.
class OneWriterTest < ActiveSupport::TestCase
  ROOT = Rails.root
  EVENT_LOG = "lib/leverage/event_log.rb".freeze

  EVENT_INSERT = [
    /\bEvent\s*\.\s*(new|create!?|insert(_all)?!?|upsert(_all)?|find_or_create_by!?|create_or_find_by!?)\b/,
    /\bINSERT\s+INTO\s+("?public"?\.)?"?events"?[\s(]/i,
    /\bcopy_from\b.*\bevents\b/i
  ].freeze

  WRITE = [
    /\.\s*(save!?|update!?|update_all|update_column|update_columns|update_attribute|create!?|insert(_all)?!?|upsert(_all)?|destroy!?|destroy_all|delete_all|delete_by|destroy_by|increment!|decrement!|toggle!|touch|lock!|find_or_create_by!?|create_or_find_by!?)\b/,
    /\b(INSERT\s+INTO|UPDATE\s+"?\w+"?\s+SET|DELETE\s+FROM|TRUNCATE|SELECT\s+.*\bFOR\s+UPDATE)\b/i
  ].freeze

  # The folders of the third line, which only read (milestone 4 plan §2).
  READ_ONLY_RULES = [].freeze

  def self.code_lines(text)
    text.each_line.with_index(1).reject { |line, _| line.strip.start_with?("#") }
  end

  def self.offences(files, patterns)
    files.flat_map do |file|
      code_lines(File.read(file)).filter_map do |line, number|
        "#{file.delete_prefix("#{ROOT}/")}:#{number}: #{line.strip}" if patterns.any? { |pattern| pattern.match?(line) }
      end
    end
  end

  # The writes in the files of READ_ONLY_RULES under root.
  def self.rules_offences(root)
    files = READ_ONLY_RULES.flat_map { |folder| Dir[File.join(root.to_s, folder, "**", "*.rb")] }.sort
    offences(files, WRITE)
  end

  def ruby_files(*folders)
    folders.flat_map { |folder| Dir[ROOT.join(folder, "**", "*.rb")] }.sort
  end

  test "only event_log.rb inserts into events" do
    files = ruby_files("app", "lib", "config", "script", "db") - [ ROOT.join(EVENT_LOG).to_s ]

    assert_empty self.class.offences(files, EVENT_INSERT)
    assert_not_empty self.class.offences([ ROOT.join(EVENT_LOG).to_s ], EVENT_INSERT), "the scan no longer sees event_log.rb's insert"
  end

  test "controllers and reads call no writing Active Record method" do
    assert_empty self.class.offences(ruby_files("app/controllers", "lib/leverage/reads"), WRITE)
  end

  test "the scans catch what they look for and skip comments" do
    sample = Tempfile.new([ "sample", ".rb" ])
    sample.write(<<~RUBY)
      Event.create!(type: "task.created")
      connection.execute("INSERT INTO events (id) VALUES ($1)")
      task.update!(state: "ready")
      Task.where(id: id).update_all(state: "ready")
      # Event.create! in a comment is not code
    RUBY
    sample.close

    assert_equal 2, self.class.offences([ sample.path ], EVENT_INSERT).size
    assert_equal 4, self.class.offences([ sample.path ], WRITE).size
  ensure
    sample&.unlink
  end

  test "files under lib/leverage/rules call no writing Active Record method" do
    assert_not_empty Dir[ROOT.join("lib/leverage/rules/**/*.rb")]
    assert_empty self.class.rules_offences(ROOT)
  end

  test "the rules scan reports a write in a file under rules/" do
    Dir.mktmpdir do |root|
      path = File.join(root, "lib/leverage/rules/made_up.rb")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "rule.update!(enabled: false)\n# rule.update!(enabled: true) in a comment is not code\n")

      assert_equal 1, self.class.rules_offences(root).size
    end
  end
end
