# A login or an API token the owner added (PRD, Credentials). Its name is kept
# here and nowhere else (L572).
# An Active Record class with no callbacks (milestone 2 plan §2.1).
class Credential < ApplicationRecord
  # The credentials whose Add credential finished: its checks passed
  # (IN-24). A row whose add is still running has no last_verified_at.
  scope :added, -> { where.not(last_verified_at: nil) }
  scope :tokens, -> { where(kind: "api_token") }

  # Add and Rename use the same spelling, including when comparing names
  # saved by an older version that allowed surrounding whitespace.
  def self.trim_name(value)
    value.gsub(/\A[[:space:]]+|[[:space:]]+\z/, "") if value.is_a?(String)
  end

  def self.name_taken?(workspace_id:, provider:, kind:, name:, except: nil)
    others = where(workspace_id: workspace_id, provider: provider, kind: kind)
    others = others.where.not(id: except) if except
    others.pluck(:name).any? { |saved| trim_name(saved) == name }
  end

  # Whether a limit holds at time at (milestone 3 plan HE-3, §2.1 rule 2):
  # one was reported (limited_since) and it has no reset time, or its reset
  # time is later than at. Nothing is written when the reset time passes.
  def limited?(at)
    !limited_since.nil? && (limited_until.nil? || limited_until > at)
  end
end
