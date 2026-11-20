module Leverage
  module Rules
    # The providers that have built a task (PRD L448, L690; milestone 4
    # plan §2.1, RD-50), read from the log: the provider of every
    # credential recorded as doing its build work, in task.claimed and in
    # each credential.switched of the build work (one that names neither a
    # review nor a job), and the provider of every seat that held it with
    # no credential (task.claimed with no credential, or a fresh lease given
    # to a seat that connects on its own). A provider counts as its group: a
    # login and an API token of one vendor are one provider, and OpenRouter
    # is its own (L448, the registry's credential_providers). It reads only.
    module ProviderRecord
      # Events that give a builder a lease on a task besides task.claimed:
      # each names the seat in lease_seat_id.
      LEASE_GRANTS = %w[review.failed hold.closed task.returned_for_rework].freeze

      module_function

      # The provider groups that have built the task, in the order they
      # first did; none for a task no builder held, or no task.
      #
      # Returns an Array of Strings.
      def groups(task_id)
        task = Task.find_by(id: task_id)
        return [] unless task

        credential_ids, seat_ids = builders(task)
        providers = Credential.where(id: credential_ids).pluck(:id, :provider).to_h
        seats = Seat.where(id: seat_ids).pluck(:id, :provider, :credential_id).to_h { |id, *rest| [ id, rest ] }
        own = seat_ids.filter_map do |seat_id|
          provider, credential_id = seats[seat_id]
          provider if credential_id.nil?
        end
        (credential_ids.filter_map { |id| providers[id] } + own).map { |provider| group(provider) }.uniq
      end

      # The provider group of a credential_providers value; a provider the
      # registry does not list is its own group, as in Candidates.
      def group(provider)
        @groups ||= Contract.registry.fetch("credential_providers")
          .to_h { |entry| [ entry.fetch("provider"), entry.fetch("provider_group") ] }.freeze
        @groups.fetch(provider, provider)
      end

      # The credentials that did the task's build work, and the seats given
      # a builder lease on it with no credential named, in log order.
      def builders(task)
        credential_ids = []
        seat_ids = []
        Event.where(workspace_id: task.workspace_id, task_id: task.id,
          type: [ Leases::BUILDER_GRANT, "credential.switched", *LEASE_GRANTS ]).order(:seq).each do |event|
          payload = event.payload
          case event.type
          when Leases::BUILDER_GRANT
            payload["credential_id"] ? credential_ids << payload["credential_id"] : seat_ids << payload["seat_id"]
          when "credential.switched"
            credential_ids << event.subject_id if payload["review_id"].nil? && payload["job_id"].nil?
          else
            seat_ids << payload["lease_seat_id"] if payload["lease_seat_id"]
          end
        end
        [ credential_ids.uniq, seat_ids.uniq ]
      end

      private_class_method :builders
    end
  end
end
