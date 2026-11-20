# The Rule checks milestone's additions to the Data model (milestone 4 plan,
# section 2.3): the request a pending transition completes with, and which
# try of its check or draft a job is. Forward only (PRD, Data model); it
# touches no event.
class AddRuleCheckColumns < ActiveRecord::Migration[8.1]
  def change
    # The request is content (L221) and nothing else can carry it: a
    # pending transition keeps it while it waits, and the column is emptied
    # when it leaves pending (RE-2). Like a stored command outcome, it never
    # holds a key named token or ending in _token, at any depth (IF-15).
    add_column :pending_transitions, :params, :jsonb
    add_check_constraint :pending_transitions, "params IS NULL OR state = 'pending'",
      name: "pending_transitions_params_only_while_pending"
    add_check_constraint :pending_transitions,
      %(params IS NULL OR NOT jsonb_path_exists(params, '$.** ? (@.type() == "object").keyvalue() ? (@.key like_regex "(^|_)token$" flag "i")')),
      name: "pending_transitions_params_hold_no_token"

    # Each try of a check or a draft is a job of its own; a draft's second
    # miss must know it is the second (DB-31). A rule check's number is its
    # attempt's.
    add_column :jobs, :attempt_number, :integer, null: false, default: 1
  end
end
