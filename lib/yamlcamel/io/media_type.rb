# frozen_string_literal: true

module YAMLCamel
  module IO
    # The media types this library sends and accepts.
    module MediaType
      # The type registered for YAML in RFC 9512, and the one every request here sends.
      CANONICAL = "application/yaml"

      # Types accepted on a response, since servers predating RFC 9512 use the older spellings.
      ACCEPTED = ["application/yaml", "text/yaml", "application/x-yaml", "text/x-yaml", "text/plain"].freeze

      module_function

      # True when a Content-Type header names YAML. Parameters after a semicolon are ignored.
      def yaml?(content_type)
        return false if content_type.nil?

        base = content_type.to_s.split(";").first.to_s.strip.downcase
        ACCEPTED.include?(base)
      end
    end

    # Bounds applied to a transfer, whichever direction it runs in.
    #
    # These sit apart from Limits because they bound the bytes rather than the document: how much a
    # server may hand over, and how far a compressed body may expand once it is inflated.
    class TransferLimits
      attr_reader :max_body_bytes, :max_inflated_bytes

      def initialize(max_body_bytes: 16 << 20, max_inflated_bytes: 64 << 20)
        @max_body_bytes = max_body_bytes
        @max_inflated_bytes = max_inflated_bytes
        freeze
      end

      def with(**overrides)
        TransferLimits.new(**to_h.merge(overrides))
      end

      def to_h = { max_body_bytes: @max_body_bytes, max_inflated_bytes: @max_inflated_bytes }

      def ==(other) = other.is_a?(TransferLimits) && to_h == other.to_h
      alias eql? ==

      def hash = to_h.hash

      def self.default = DEFAULT

      DEFAULT = new
    end
  end
end
