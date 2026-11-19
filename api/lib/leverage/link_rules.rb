require "uri"

module Leverage
  # What a work reference or a piece of evidence may carry (PRD L533; IF-3):
  # evidence is an https link or a note, and a work reference or an evidence
  # link that carries sign-in details, a user and password in the address or
  # a token in the query, is refused. The server never fetches a link or
  # opens a reference; it only reads the text. An entry answers a problem
  # with 422 invalid.
  module LinkRules
    EVIDENCE_KINDS = %w[link note].freeze

    # Query parameters that carry a secret: a token, a key, a password or a
    # signature, as the usual names spell them.
    SECRET_PARAMETER = /token|secret|passw|pwd|api[-_]?key|\Akey\z|\Aauth|signature|\Asig\z|credential|session/i

    # An address with a scheme, inside free text.
    ADDRESS = %r{[a-z][a-z0-9+.-]*://[^\s<>"']+}i

    # user:password@host with no scheme (an scp-like reference).
    BARE_USER_AND_PASSWORD = %r{(?:\A|[\s(])[^\s/@:]+:[^\s/@]+@[^\s/:]+}

    module_function

    # Why a piece of evidence is refused, or nil when it is accepted.
    def evidence_problem(kind, value)
      return "Evidence is a link or a note." unless EVIDENCE_KINDS.include?(kind)
      return nil if kind == "note"

      uri = parse(value.to_s.strip)
      return "An evidence link is an https address." unless uri.is_a?(URI::HTTPS) && uri.host.to_s != ""

      address_problem(uri)
    end

    # Why a work reference is refused, or nil when it is accepted. nil and
    # an empty reference are accepted: the reference is optional.
    def work_reference_problem(reference)
      text = reference.to_s
      return nil if text.strip.empty?
      return "A work reference may not carry a user and password." if BARE_USER_AND_PASSWORD.match?(text)

      text.scan(ADDRESS).each do |address|
        uri = parse(address)
        return "A work reference may not carry sign-in details." unless uri

        problem = address_problem(uri)
        return problem.sub("An evidence link", "A work reference") if problem
      end
      nil
    end

    # Sign-in details in a parsed address: any user on a web address, a
    # password on any address, a secret named in the query.
    def address_problem(uri)
      userinfo = uri.userinfo.to_s
      web = uri.is_a?(URI::HTTP)
      return "An evidence link may not carry a user and password." if userinfo.include?(":") || (web && !userinfo.empty?)

      names = URI.decode_www_form(uri.query.to_s).map(&:first)
      return "An evidence link may not carry a token in its query." if names.any? { |name| SECRET_PARAMETER.match?(name) }

      nil
    rescue ArgumentError
      "An evidence link's query cannot be read."
    end

    def parse(text)
      URI.parse(text)
    rescue URI::InvalidURIError
      nil
    end

    private_class_method :address_problem, :parse
  end
end
