# The core loop's two additions to the Data model (milestone 2 plan IN-22,
# IN-23, IN-30), and the column that keeps a helper request's per-check
# progress while it runs.
class AddCoreLoopColumns < ActiveRecord::Migration[8.1]
  # No key named name, and no key named token or ending in _token, in any
  # letter case, at any depth: a credential's name is kept in its own row
  # only (L572), and a token is never stored (IF-15). The token test is the
  # one the commands and helper_requests.result constraints use.
  def self.no_name_or_token_key(column)
    %(NOT jsonb_path_exists(#{column}, '$.** ? (@.type() == "object").keyvalue() ? (@.key like_regex "^name$|(^|_)token$" flag "i")'))
  end

  def change
    # The non-secret inputs the helper has no other way to learn: the
    # provider and kind of a credential request, the role, provider, model
    # and effort of a seat request (IN-22).
    add_column :helper_requests, :params, :jsonb, null: false, default: {}
    # Each check's state while the request runs, which the app follows
    # (IN-23). The outcome stays in result.
    add_column :helper_requests, :progress, :jsonb, null: false, default: []
    add_check_constraint :helper_requests, no_name_or_token_key("params"), name: "helper_requests_params_hold_no_name_or_token"
    add_check_constraint :helper_requests, no_name_or_token_key("progress"), name: "helper_requests_progress_holds_no_name_or_token"

    # Set by Start (and by Connect for a seat the app runs), cleared by Stop
    # and Remove; issuing the helper's token starts every seat wanted
    # running (IN-30).
    add_column :seats, :wanted_running, :boolean, null: false, default: false
  end

  private

  def no_name_or_token_key(column) = self.class.no_name_or_token_key(column)
end
