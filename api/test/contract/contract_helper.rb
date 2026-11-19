# Shared setup for the contract tests (test/contract/**/*_test.rb).
#
# They need no database and no Rails: bin/contract_test runs them with plain
# Minitest. Inside `bin/rails test` they run in the same process as the
# database tests, so lib/ must then be loaded by the application's own
# Zeitwerk loader, never by a second one (two loaders on one folder is an
# error) and never by a plain require of an autoloaded file.
require "json"
require "json_schemer"

if defined?(Rails)
  ENV["RAILS_ENV"] ||= "test"
  require_relative "../../config/environment"
else
  require "zeitwerk"
  lib = File.expand_path("../../lib", __dir__)
  loader = Zeitwerk::Loader.new
  loader.push_dir(lib)
  loader.ignore(File.join(lib, "tasks"))
  loader.setup
end

require "minitest/autorun"

module ContractTestHelpers
  CONTRACT_ROOT = File.expand_path("../../contract", __dir__)

  SNAKE_CASE = /\A[a-z][a-z0-9]*(_[a-z0-9]+)*\z/
  DOTTED = /\A[a-z]+(_[a-z]+)*\.[a-z]+(_[a-z]+)*\z/

  def registry
    Leverage::Contract.registry
  end

  # Errors from validating data against one of the contract's meta-schemas.
  def meta_errors(meta_name, data)
    schema = JSONSchemer.schema(Leverage::Contract.meta_schema(meta_name))
    schema.validate(data).map { |error| error.fetch("error") }
  end

  def duplicates(values)
    values.tally.select { |_, count| count > 1 }.keys
  end
end
