require "bundler"
require "minitest/autorun"

# ADR 0002 point 2 leaves Action Mailer, Action Mailbox, Action Text,
# Active Storage and Action Cable out of the API. Not requiring their
# railties is not enough: the `rails` gem depends on every one of them, so
# they and their own dependencies would still be locked and installed in the
# image. Plain Minitest, no Rails and no database.
class DependenciesTest < Minitest::Test
  LEFT_OUT = %w[
    rails actioncable actionmailbox actionmailer actiontext activestorage
    action_text-trix mail net-imap net-pop net-smtp
  ].freeze

  def test_the_frameworks_adr_0002_leaves_out_are_not_locked
    lockfile = File.expand_path("../Gemfile.lock", __dir__)
    locked = Bundler::LockfileParser.new(File.read(lockfile)).specs.map(&:name)

    assert_empty LEFT_OUT & locked
  end
end
