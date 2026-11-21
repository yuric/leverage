# One usage reading of a credential (milestone 6).
# An Active Record class with no callbacks and no logic (milestone 2 plan §2.1).
class CredentialReading < ApplicationRecord
  scope :newest_for, ->(credential) { none }
end
