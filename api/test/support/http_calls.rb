# Sends one served operation over HTTP the way a client does (milestone 2
# plan WP17): the method and path come from the registry, never typed in a
# test; the token goes in the Authorization header, the key in
# Idempotency-Key, and a body as JSON. Every request a test means to be
# valid is held to openapi.json first, and the answer is returned for the
# test to hold to it (OpenapiAssertions).
#
#   include HttpCalls
#   call("claim_next_task", token: builder_token, key: "key-1")
#   call("pass_criterion", token: builder_token, key: "key-2",
#        ids: { "id" => task.id, "cid" => criterion.id }, body: { "evidence" => ... })
#   call("get_next", token: builder_token, query: { "wait" => 0 })
module HttpCalls
  # A registry operation by id.
  def self.operation(operation_id)
    @operations ||= Leverage::Contract.registry.fetch("operations").to_h { |op| [ op.fetch("operation_id"), op ] }
    @operations.fetch(operation_id)
  end

  # The served operations (Http::RouteTable) as registry rows.
  def self.served
    Leverage::Http::RouteTable::ROUTES.keys.map { |operation_id| operation(operation_id) }
  end

  # The served operations that change something: every POST.
  def self.mutating
    served.select { |op| op.fetch("method") == "POST" }.map { |op| op.fetch("operation_id") }
  end

  # The registry path with its parameters filled in.
  def self.path(operation_id, ids = {})
    operation(operation_id).fetch("path").gsub(/\{([a-z]+)\}/) do
      ids.fetch(Regexp.last_match(1)) { raise ArgumentError, "#{operation_id} needs #{Regexp.last_match(1)}" }
    end
  end

  # Sends the operation and returns the response. body nil sends no body;
  # raw: sends these bytes as the body instead of body's JSON.
  def call(operation_id, token: nil, key: nil, ids: {}, body: nil, query: nil, check_request: true, raw: nil)
    op = HttpCalls.operation(operation_id)
    path = HttpCalls.path(operation_id, ids)
    headers = {}
    headers["Authorization"] = "Bearer #{token}" if token
    headers["Idempotency-Key"] = key if key
    path = "#{path}?#{query.to_query}" if query
    if op.fetch("method") == "GET"
      get path, headers: headers
    else
      if body
        headers["Content-Type"] = "application/json"
        assert_request_matches_contract("POST", path, body) if check_request
      end
      post path, params: raw || (body && JSON.generate(body)), headers: headers
    end
    response
  end

  def new_key(prefix = "key") = "#{prefix}-#{SecureRandom.hex(8)}"
end
