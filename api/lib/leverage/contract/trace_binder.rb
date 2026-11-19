require "digest"
require "time"

module Leverage
  module Contract
    # Turns a golden trace's symbols into values (api/contract/README.md,
    # "Golden traces"):
    #
    #   $kind:name   an id: a UUIDv5 of the symbol under NAMESPACE, the same
    #                in every run, so two symbols never share an id
    #   @event:n     the id of the trace's n-th expected event (from 1)
    #   @t:seconds   the trace's start plus that many seconds, as ISO 8601
    #
    # Any other string that starts with "$" or "@" is a mistake and raises.
    class TraceBinder
      NAMESPACE = "3c9f6a0e-6d3b-4f21-9a57-0b6e2d4c8f15"

      SYMBOL = /\A\$[a-z][a-z_]*:[a-z0-9][a-z0-9_]*\z/
      EVENT = /\A@event:([1-9][0-9]*)\z/
      TIME = /\A@t:(-?[0-9]+)\z/

      # RFC 9562 version 5: SHA-1 of the namespace's bytes and the name.
      def self.uuid_v5(namespace, name)
        bytes = Digest::SHA1.digest([ namespace.delete("-") ].pack("H*") + name.b).bytes.first(16)
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        hex = bytes.pack("C*").unpack1("H*")
        [ hex[0, 8], hex[8, 4], hex[12, 4], hex[16, 4], hex[20, 12] ].join("-")
      end

      attr_reader :start

      def initialize(start:)
        @start = start
      end

      def id(symbol)
        raise ArgumentError, "not a trace symbol: #{symbol.inspect}" unless SYMBOL.match?(symbol)

        self.class.uuid_v5(NAMESPACE, symbol)
      end

      def event_id(number)
        raise ArgumentError, "events are counted from 1: #{number.inspect}" unless number.is_a?(Integer) && number >= 1

        self.class.uuid_v5(NAMESPACE, "@event:#{number}")
      end

      def time(seconds)
        start + seconds
      end

      # A copy of value with every symbol, event link and relative time
      # replaced; other values are kept as they are.
      def bind(value)
        case value
        when Hash then value.to_h { |key, item| [ key, bind(item) ] }
        when Array then value.map { |item| bind(item) }
        when String then bind_string(value)
        else value
        end
      end

      private

      def bind_string(value)
        return value unless value.start_with?("$", "@")
        return id(value) if SYMBOL.match?(value)

        if (match = EVENT.match(value))
          event_id(Integer(match[1], 10))
        elsif (match = TIME.match(value))
          time(Integer(match[1], 10)).utc.iso8601(6)
        else
          raise ArgumentError, "unknown symbol form: #{value.inspect}"
        end
      end
    end
  end
end
