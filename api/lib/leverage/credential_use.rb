module Leverage
  module CredentialUse
    module_function

    def in_use?(credential) = false
    def release(ctx, credential); end
  end
end
