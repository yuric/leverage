module Leverage
  # A workspace's rules and their versions (PRD L342, L379, L434;
  # milestone 4 plan RD-1 to RD-7, RD-21 to RD-24): the only writer of
  # rules and rule_versions. Writes the shipped set (Rules::Shipped), adds a
  # custom rule, saves a version, switches a rule on or off, reverts a
  # shipped rule, removes a custom one, and says what switching off
  # withdraws (L379).
  #
  # First version (milestone 4 plan §4, the hand-over table): every call
  # does nothing; install_shipped answers [] and the others nil. WP8
  # writes it.
  module RuleRecords
    module_function

    # Writes the seven shipped rules at version 1, each with rule.created
    # (create_owner, install_shipped_rules). Returns the Rules.
    def install_shipped(ctx)
      []
    end

    # Adds a custom rule from fields (AddRuleRequest's). Returns the Rule.
    def add(ctx, fields)
      nil
    end

    # Saves fields (SaveRuleRequest's) as the rule's next version.
    def save(ctx, rule, fields)
      nil
    end

    def enable(ctx, rule)
      nil
    end

    def disable(ctx, rule)
      nil
    end

    # Writes the shipped default as the rule's next version.
    def revert(ctx, rule)
      nil
    end

    def remove(ctx, rule)
      nil
    end
  end
end
