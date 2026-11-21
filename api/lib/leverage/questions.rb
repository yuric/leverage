module Leverage
  module Questions
    module_function

    def ask(_ctx, _task, text:, assumption:, blocking:) = nil
    def route(_ctx, _question, _effect) = nil
    def answer(_ctx, _question, by:, text:, basis:) = nil
    def pass_on(_ctx, _question) = nil
    def overturn(_ctx, _question) = nil
  end
end
