module V1
  module Owner
    # issue_helper_token (milestone 2 plan IN-11, IN-30): the owner's app asks
    # for the helper's token, which the first answer of the key carries
    # once (HelperTokenIssued) and a repeat leaves out
    # (HelperTokenIssuedRepeated). The entry is issue_helper_token's.
    class HelpersController < ApplicationController
      include AuthenticatesOwner
      include RunsCommands

      # POST /v1/owner/helpers
      def create
        body = Leverage::Http::RequestSchema.body!("issue_helper_token", request.raw_post)
        run_command("issue_helper_token", params: body)
      end
    end
  end
end
