module Leverage
  # The contract's model choices for a login provider. A Prompt seat reports
  # its actual model and effort. A Native seat uses the tool's defaults for
  # empty choices and can set effort only if the runner passes it.
  module ModelCatalog
    module_function

    def provider?(provider) = !provider_entry(provider).nil?
    def models(provider) = entries(provider).map { |model| model.fetch("id") }
    def native_effort?(provider) = provider_entry(provider)&.dig("native_effort", "value") == true

    def efforts(provider, model)
      entry = entries(provider).find { |candidate| candidate.fetch("id") == model }
      entry&.dig("efforts", "values") || []
    end

    def reportable_models(provider)
      entries(provider).map { |model| { id: model.fetch("id"), efforts: model.dig("efforts", "values") || [] } }
    end

    def problem(provider:, model:, effort:, native:)
      model = model.to_s
      effort = effort.to_s
      default = native ? "the tool's default" : "null if unknown"
      unless model.empty?
        choices = models(provider)
        unless choices.include?(model)
          return "#{provider} has no model #{model.inspect}. Pick #{choices_with_default(choices, default)}."
        end
      end

      return if effort.empty?
      return "Choose a model before setting effort. With the model unknown or set to the tool's default, use #{default} for effort." if model.empty?
      return "The #{provider} runner only accepts the tool's default for effort." if native && !native_effort?(provider)

      choices = efforts(provider, model)
      return if choices.include?(effort)

      "#{model} has no effort #{effort.inspect}. Pick #{choices_with_default(choices, default)}."
    end

    def choices_with_default(choices, default)
      choices.empty? ? default : "#{choices.join(', ')}, or #{default}"
    end
    private_class_method :choices_with_default

    def entries(provider) = provider_entry(provider)&.fetch("models") || []
    private_class_method :entries

    def provider_entry(provider)
      Contract.models.fetch("providers").find { |entry| entry.fetch("provider") == provider }
    end
    private_class_method :provider_entry
  end
end
