# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  /\A(?:name|plan)\z/
]

# A Leverage token (lvs_ seat, lvh_ helper, lvo_ owner session; milestone 2
# plan IN-18) is filtered wherever it appears in a logged value, whatever
# the parameter is called: the names above catch the fields meant to hold
# one, and this catches a token sent where none belongs. The form is
# Leverage::Tokens::FORM's, without the anchors; the constant is not
# loaded this early.
LEVERAGE_TOKEN_IN_TEXT = /lv[sho]_[A-Za-z0-9_-]{43}/
Rails.application.config.filter_parameters << lambda do |_key, value|
  value.gsub!(LEVERAGE_TOKEN_IN_TEXT, "[FILTERED]") if value.is_a?(String) && !value.frozen?
end

# Every other text a request carries is content or may be (task text, a
# rule's name and instruction, a checker's reason, an override reason, notes,
# evidence; PRD, Privacy; milestone 4 plan RT-8): the log keeps each
# parameter's key, and its value only when the value is an id. Numbers and
# true or false are kept; they are never content. Names and plans are
# filtered above even when they look like ids.
LEVERAGE_ID_IN_TEXT = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
Rails.application.config.filter_parameters << lambda do |_key, value|
  value.replace("[FILTERED]") if value.is_a?(String) && !value.frozen? && !value.match?(LEVERAGE_ID_IN_TEXT)
end
