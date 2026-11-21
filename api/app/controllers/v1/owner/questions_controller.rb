module V1
  module Owner
    class QuestionsController < ApplicationController
      include AuthenticatesOwner
      include RunsCommands

      def answer = control("answer_question")
      def overturn = control("overturn_answer")

      private

      def control(command)
        run_command(command, params: checked_body(command).merge("id" => uuid_param!(:id)))
      end
    end
  end
end
