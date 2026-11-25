require "json"
require "json_schemer"
require "pathname"

module Leverage
  # Reads the shared contract in api/contract/ (see its README.md): each
  # file is parsed once and deep-frozen, and event payloads are validated
  # against their versioned JSON Schemas. Works with or without Rails.
  module Contract
    @mutex = Mutex.new
    @root = nil
    @files = {}
    @schemers = {}

    class << self
      # The contract folder: Rails.root/contract, or api/contract found from
      # this file when Rails is not loaded.
      def root
        @root || default_root
      end

      # Points the loader at another folder (tests only) and drops every
      # file already read. nil goes back to the default.
      def root=(path)
        @mutex.synchronize do
          @root = path && Pathname.new(path)
          @files = {}
          @schemers = {}
        end
      end

      # The parsed, deep-frozen content of a file, by its path inside the
      # contract folder ("registry.json", "payloads/task.created.v1.json").
      def load(relative)
        cached = @files[relative]
        return cached if cached

        @mutex.synchronize do
          @files[relative] ||= JSON.parse(root.join(relative).read, freeze: true)
        end
      end

      def registry = load("registry.json")
      def state_machine = load("state_machine.json")
      def steps = load("steps.json")
      def hooks = load("hooks.json")
      def shipped_rules = load("shipped_rules.json")
      def jobs = load("jobs.json")
      def roles = load("roles.json")
      def timers = load("timers.json")
      def needs_you = load("needs_you.json")
      def readers = load("readers.json")
      def models = load("models.json")
      def openapi = load("openapi.json")

      # A meta-schema under meta/, by name: meta_schema("registry").
      def meta_schema(name)
        load("meta/#{name}.schema.json")
      end

      # A golden trace under traces/, by name: trace("01-happy-path").
      def trace(name)
        load("traces/#{name}.json")
      end

      # One of the registry's closed vocabularies: list("task_states").
      def list(name)
        registry.fetch("lists").fetch(name)
      end

      # The registry entry of an event type. Raises KeyError when the type
      # is not registered.
      def event_type(type)
        registry.fetch("event_types").find { |entry| entry["type"] == type } ||
          raise(KeyError, "event type not registered: #{type}")
      end

      # The payload schema of a registered (type, version). Raises KeyError
      # when that version of the type is not registered.
      def payload_schema(type, version)
        unless event_type(type).fetch("schema_versions").include?(version)
          raise KeyError, "#{type} has no registered schema version #{version}"
        end

        load("payloads/#{type}.v#{version}.json")
      end

      # The errors of a payload against its schema; empty when it is valid.
      # The payload is checked in the form it is stored in (its JSON), so
      # symbol keys and string keys validate alike.
      def validate_payload(type, version, payload)
        stored = JSON.parse(JSON.generate(payload))
        schemer(type, version).validate(stored).map { |error| error.fetch("error") }
      end

      private

      def default_root
        if defined?(Rails) && Rails.respond_to?(:root) && Rails.root
          Rails.root.join("contract")
        else
          Pathname.new(File.expand_path("../../contract", __dir__))
        end
      end

      def schemer(type, version)
        schema = payload_schema(type, version)
        key = "#{type}.v#{version}"
        @schemers[key] || @mutex.synchronize { @schemers[key] ||= JSONSchemer.schema(schema) }
      end
    end
  end
end
