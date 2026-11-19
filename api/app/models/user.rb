# The owner: the workspace's one user (milestone 2 plan IN-2). The password
# is kept as a bcrypt digest (DB-40, IN-4); has_secure_password checks it.
# An Active Record class with no callbacks and no logic (milestone 2 plan §2.1).
class User < ApplicationRecord
  has_secure_password
end
