module V1
  module Owner
    class ProjectsController < ApplicationController
      include AuthenticatesOwner
      include RunsCommands

      def index
        render json: Leverage::Reads::Projects.call(current_caller.workspace_id)
      end

      def create = run_command("create_project", params: checked_body("create_project"))
      def brief = control("edit_brief")
      def pause = control("pause_project")
      def resume = control("resume_project")
      def budget = control("change_budget")

      def delete_content
        body = checked_body("delete_project_content")
        run_command("delete_content", params: body.merge("project_id" => uuid_param!(:id)))
      end

      private

      def control(command)
        run_command(command, params: checked_body(command).merge("id" => uuid_param!(:id)))
      end
    end
  end
end
