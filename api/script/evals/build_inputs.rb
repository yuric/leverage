# The eval suite's job inputs (milestone 4 plan RV-3, RV-6). Not built yet:
# every method answers nothing.
module EvalInputs
  module_function

  def read_cases(_folder) = []
  def contract(kase, canary_path:) = kase.fetch("contract")
  def input_for(_kase, canary_path:) = {}
  def suite(_folder, canary_path:) = { "suite" => nil, "cases" => [] }
end
