# One idempotent call: its key, its request hash and its outcome (PRD L220;
# IF-4). Written only by Leverage::Idempotency.
# An Active Record class with no callbacks and no logic (milestone 2 plan §2.1).
class Command < ApplicationRecord
end
