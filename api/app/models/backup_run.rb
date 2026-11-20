# One database backup: when it ran, the dump's file name and its size
# (PRD Data model; milestone 3 plan HB-4). The application's role may only
# read it; the backup, run as the owner role, writes it.
# An Active Record class with no callbacks and no logic (milestone 2 plan §2.1).
class BackupRun < ApplicationRecord
end
