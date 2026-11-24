# Credentials milestone, CR-7: the server may keep only the fixed mask.
class ConstrainMaskedLabel < ActiveRecord::Migration[8.1]
  def up
    # Older clients could submit an arbitrary label. Discard it on upgrade.
    execute <<~SQL
      UPDATE credentials SET masked_label = NULL WHERE masked_label <> '••••••••'
    SQL
    add_check_constraint :credentials, "masked_label IS NULL OR masked_label = '••••••••'",
      name: "credentials_masked_label_is_fixed"
  end
end
