module Leverage
  # Positions in one workspace's handoff order (PRD, Handoff). The caller
  # holds the workspace lock inside a transaction, so the deferred position
  # constraint is checked after the whole move. Entries write any events.
  class CredentialOrder
    def initialize(workspace_id)
      @credentials = Credential.where(workspace_id: workspace_id)
    end

    # Place the credential whose checks just passed (CR-29). Its Add
    # already reserved a position, which does not determine where it lands.
    def place(credential)
      others = @credentials.where.not(id: credential.id)
      first_token = others.added.tokens.order(:position).first if credential.kind == "login"
      position = if first_token
        others.where(position: first_token.position..).update_all("position = position + 1")
        first_token.position
      else
        others.maximum(:position).to_i + 1
      end
      credential.update_columns(position: position) if credential.position != position
    end

    def exactly_the_added?(ids)
      added = @credentials.added.pluck(:id)
      ids.size == added.size && ids.to_set == added.to_set
    end

    # The caller has checked the added set. Keep pending Adds after the
    # added rows, in their existing order. Report only changed added rows,
    # in their new order, so the caller can write credential.order_changed.
    def apply(ids)
      added = @credentials.added.order(:position).index_by(&:id)
      return [] if ids == added.keys

      ordered = ids.map { |id| added.fetch(id) }
      pending = @credentials.where.not(id: ids).order(:position)
      (ordered + pending).each_with_index do |credential, index|
        position = index + 1
        credential.update_columns(position: position) unless credential.position == position
      end
      old_order = added.keys
      ordered.each_with_index.filter_map { |credential, index| credential if credential.id != old_order[index] }
    end
  end
end
