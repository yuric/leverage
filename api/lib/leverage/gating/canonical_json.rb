require "json"

module Leverage
  module Gating
    # The one JSON form an input hash is taken over: object keys sorted by
    # code point, no whitespace, UTF-8, integers in decimal. Only String,
    # Integer, true, false, nil, Array and Hash with String keys have that
    # form; anything else (a Float, a Time, a Symbol, a BigDecimal) raises
    # ArgumentError, so two callers can never hash one value two ways.
    module CanonicalJson
      def self.dump(value)
        case value
        when Hash then dump_object(value)
        when Array then "[#{value.map { |item| dump(item) }.join(",")}]"
        when String then dump_string(value)
        when Integer, true, false, nil then JSON.generate(value)
        else raise ArgumentError, "no canonical JSON form for #{value.class}"
        end
      end

      def self.dump_object(hash)
        hash.each_key { |key| raise ArgumentError, "object keys must be strings, got #{key.inspect}" unless key.is_a?(String) }
        pairs = hash.keys.sort.map { |key| "#{dump_string(key)}:#{dump(hash[key])}" }
        "{#{pairs.join(",")}}"
      end

      def self.dump_string(string)
        utf8 = string.encode(Encoding::UTF_8)
        raise ArgumentError, "string is not valid UTF-8" unless utf8.valid_encoding?

        JSON.generate(utf8)
      rescue EncodingError => e
        raise ArgumentError, e.message
      end

      private_class_method :dump_object, :dump_string
    end
  end
end
