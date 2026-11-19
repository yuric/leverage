require "digest"
require "securerandom"

module Leverage
  # Bearer tokens (milestone 2 plan IN-17, IN-18): a prefix that names the
  # kind (lvs_ seat, lvh_ helper, lvo_ owner session) and 32 random bytes
  # in URL-safe base64. The server stores only the SHA-256 hex and finds
  # the caller by it; the prefix lets the redaction and the secret scan
  # recognise a token anywhere.
  module Tokens
    PREFIXES = { seat: "lvs_", helper: "lvh_", owner: "lvo_" }.freeze
    FORM = /\Alv[sho]_[A-Za-z0-9_-]{43}\z/

    # Who a token signed in: kind is "seat", "owner" or "helper"; id is the
    # seat, the owner's user or the helper; record is the Seat, the Session
    # or the Helper.
    Caller = Data.define(:kind, :id, :workspace_id, :record)

    module_function

    # A new token of the kind. Nothing about it is kept but its digest.
    def issue(kind)
      prefix = PREFIXES.fetch(kind) { raise ArgumentError, "no token kind #{kind.inspect}" }
      "#{prefix}#{SecureRandom.urlsafe_base64(32, false)}"
    end

    def digest(token)
      Digest::SHA256.hexdigest(token)
    end

    # The kind a token's prefix names, or nil.
    def kind_of(token)
      PREFIXES.key(token.to_s[0, 4])
    end

    # The caller a bearer token signs in, for the kind the call expects, or
    # nil: a missing, malformed, unknown or ended token, a removed seat, a
    # deleted session, or another kind's token.
    def find(token, kind:)
      return nil unless token.is_a?(String) && FORM.match?(token) && kind_of(token) == kind

      hash = digest(token)
      case kind
      when :seat
        seat = Seat.find_by(token_hash: hash, removed_at: nil)
        seat && Caller.new(kind: "seat", id: seat.id, workspace_id: seat.workspace_id, record: seat)
      when :helper
        helper = Helper.find_by(token_hash: hash)
        helper && Caller.new(kind: "helper", id: helper.id, workspace_id: helper.workspace_id, record: helper)
      when :owner
        session = Session.find_by(token_hash: hash)
        session && Caller.new(kind: "owner", id: session.user_id, workspace_id: session.workspace_id, record: session)
      end
    end
  end
end
