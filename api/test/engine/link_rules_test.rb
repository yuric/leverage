require "test_helper"

# Leverage::LinkRules (PRD L533; IF-3): evidence is an https link or a note,
# and a work reference or an evidence link that carries sign-in details (a
# user and password in the address, or a token in the query) is refused.
# Each method returns nil when the value is accepted, or the reason it is
# refused; the entries answer 422 invalid with it.
class LinkRulesTest < ActiveSupport::TestCase
  R = Leverage::LinkRules

  test "an https link with no sign-in details is accepted as evidence" do
    assert_nil R.evidence_problem("link", "https://example.test/work/pricing/t1_copy")
    assert_nil R.evidence_problem("link", "https://example.test/search?q=prices&page=2")
  end

  test "a note is accepted as evidence whatever it says" do
    assert_nil R.evidence_problem("note", "See the second section of README.md in the work folder.")
  end

  test "evidence of a kind other than link or note is refused" do
    assert R.evidence_problem("file", "https://example.test/a")
  end

  test "an evidence link that is not https is refused" do
    assert R.evidence_problem("link", "http://example.test/work")
    assert R.evidence_problem("link", "ftp://example.test/work")
    assert R.evidence_problem("link", "example.test/work")
    assert R.evidence_problem("link", "https://")
  end

  test "an evidence link with a user and password in the address is refused" do
    assert R.evidence_problem("link", "https://made-up-user:made-up-pass@example.test/work")
    assert R.evidence_problem("link", "https://made-up-user@example.test/work")
  end

  test "an evidence link with a token in the query is refused" do
    %w[token access_token api_key apikey key secret password auth sig signature X-Amz-Signature X-Amz-Credential].each do |name|
      assert R.evidence_problem("link", "https://example.test/work?page=1&#{name}=made-up-value"), name
    end
  end

  test "a plain work reference is accepted" do
    [ nil, "", "~/work/pricing-page", "the branch pricing-page at commit abc123",
      "git@example.test:org/repo.git", "ssh://git@example.test/org/repo.git",
      "https://example.test/org/repo/tree/main" ].each do |reference|
      assert_nil R.work_reference_problem(reference), reference.inspect
    end
  end

  test "a work reference with sign-in details is refused" do
    [ "https://made-up-user:made-up-pass@example.test/org/repo",
      "https://made-up-user@example.test/org/repo",
      "ssh://git:made-up-pass@example.test/org/repo.git",
      "the repo at https://example.test/org/repo?token=made-up-value on main",
      "made-up-user:made-up-pass@example.test:org/repo.git" ].each do |reference|
      assert R.work_reference_problem(reference), reference
    end
  end
end
