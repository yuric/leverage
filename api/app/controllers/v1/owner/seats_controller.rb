module V1
  module Owner
    # The owner's seat calls: the roster, connect, start, stop and remove a
    # seat, and a seat's landing prompt (milestone 2 plan SC-10, IN-29, IN-30,
    # IN-40, MA-12, Q-15).
    #
    # A command checks its body against the contract's schema (400
    # malformed, 422 invalid), then its path id (404), and then runs the
    # entry with the body and the id as params (IN-13). Connect's first
    # answer carries the seat's token, once (IN-11).
    class SeatsController < ApplicationController
      include AuthenticatesOwner
      include RunsCommands

      def index
        render json: Leverage::Reads::Seats.call(current_caller.workspace_id)
      end

      def create
        run_command("connect_seat", params: checked_body("connect_seat"))
      end

      def start
        run_command("start_seat", params: checked_body("start_seat").merge("id" => uuid_param!(:id)))
      end

      def stop
        run_command("stop_seat", params: checked_body("stop_seat").merge("id" => uuid_param!(:id)))
      end

      def remove
        run_command("remove_seat", params: checked_body("remove_seat").merge("id" => uuid_param!(:id)))
      end

      # The owner's seat controls of milestone 3 (plan HE-27): pause and
      # resume a seat, and change its name, model, effort, strength rank,
      # login, role or whether it is on.
      def pause = control("pause_seat")
      def resume = control("resume_seat")
      def change = control("change_seat")

      # The text the owner pastes into an agent that connects on its own. A
      # seat the app runs needs none: 409 with a Refusal. It never holds the
      # seat's token.
      def landing_prompt
        prompt = Leverage::Reads::LandingPrompt.call(current_caller.workspace_id, uuid_param!(:id), base_url: request.base_url)
        raise NotFound, "No such seat" unless prompt

        render json: prompt
      rescue Leverage::Reads::LandingPrompt::AppRunSeat
        render json: Leverage::Transitions::Refusal.new(code: "invalid_state").to_h, status: :conflict
      rescue Leverage::Reads::LandingPrompt::UnusableAddress
        raise Malformed, "The address this request came in on cannot be put in a command"
      end

      private

      # The operation's id is also its command's name, as for the calls above.
      def control(command)
        run_command(command, params: checked_body(command).merge("id" => uuid_param!(:id)))
      end
    end
  end
end
