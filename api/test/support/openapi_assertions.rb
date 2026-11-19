require "json_schemer"

# Checks requests and responses against api/contract/openapi.json
# (milestone 2 plan §2.1, "Controllers and reads"). The operation is found
# by method and path, the schema by status, and json_schemer validates the
# body against it, $refs and all. A response the schema does not allow
# fails the test that produced it.
#
# In an integration test, after a request:
#
#   post "/v1/tasks/claim-next", headers: { ... }
#   assert_response_matches_contract     # this request's method, path, status and body
#
# Before sending a body the test means to be valid:
#
#   assert_request_matches_contract("POST", "/v1/owner/tasks", body)
#
# A body that is not tied to a path (a test controller's answer):
#
#   assert_matches_component("TransportError", response.parsed_body)
module OpenapiAssertions
  @mutex = Mutex.new

  # The document's schemer, built once per process.
  def self.schemer
    @schemer || @mutex.synchronize { @schemer ||= JSONSchemer.openapi(Leverage::Contract.openapi) }
  end

  def openapi_document = Leverage::Contract.openapi

  def openapi_schemer = OpenapiAssertions.schemer

  # [template, method, operation] for a concrete method and path, or nil.
  # The template with the fewest parameters wins, so a literal segment
  # (claim-next) is preferred to a parameter ({id}).
  def contract_operation(method, path)
    verb = method.to_s.downcase
    matches = openapi_document.fetch("paths").filter_map do |template, item|
      next unless item.key?(verb)

      pattern = Regexp.new("\\A#{template.gsub(/\{[a-z]+\}/, "[^/]+")}\\z")
      [ template, verb, item.fetch(verb) ] if pattern.match?(path.to_s.split("?").first)
    end
    matches.min_by { |template, _, _| template.count("{") }
  end

  def assert_request_matches_contract(method, path, body)
    template, verb, operation = contract_operation!(method, path)
    request_body = operation["requestBody"]
    if request_body.nil?
      assert body.nil? || body == {}, "#{verb.upcase} #{template} takes no body, got #{body.inspect}"
      return
    end
    pointer = "#/paths/#{escape(template)}/#{verb}/requestBody/content/application~1json/schema"
    assert_valid(pointer, body, "request to #{verb.upcase} #{template}")
  end

  def assert_response_matches_contract(method: request.request_method, path: request.path, status: response.status,
                                       body: response.parsed_body)
    template, verb, operation = contract_operation!(method, path)
    responses = operation.fetch("responses")
    entry = responses[status.to_s] || responses["default"]
    flunk "#{verb.upcase} #{template} has no #{status} response in openapi.json" unless entry

    base = if entry.key?("$ref")
      entry.fetch("$ref")
    else
      "#/paths/#{escape(template)}/#{verb}/responses/#{status}"
    end
    assert_valid("#{base}/content/application~1json/schema", body, "#{status} from #{verb.upcase} #{template}")
  end

  def assert_matches_component(name, body)
    assert_valid("#/components/schemas/#{name}", body, name)
  end

  def contract_errors(pointer, body)
    openapi_schemer.ref(pointer).validate(JSON.parse(JSON.generate(body))).map do |error|
      "#{error.fetch("data_pointer")}: #{error.fetch("error")}"
    end
  end

  def assert_valid(pointer, body, what)
    errors = contract_errors(pointer, body)
    assert_empty errors, "#{what} does not match the contract (#{pointer}):\n#{errors.join("\n")}\nbody: #{body.inspect}"
  end

  def contract_operation!(method, path)
    contract_operation(method, path) || flunk("no operation in openapi.json for #{method} #{path}")
  end

  def escape(template)
    template.gsub("~", "~0").gsub("/", "~1")
  end
end
