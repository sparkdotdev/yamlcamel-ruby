# frozen_string_literal: true

module YAMLCamel
  # Base class for every failure this library raises.
  class Error < StandardError; end

  # A stateful object built for one thread was called into from another.
  class CrossThreadUsageError < Error; end

  # A failure while reading YAML text.
  #
  # Every refusal carries a +kind+ a caller can match on without reading the message, and a 1-based
  # line number when the position is known.
  class ParseError < Error
    # The kind reported by instances of this class.
    def self.kind = :syntax

    attr_reader :kind, :line

    def initialize(message, line: 0)
      @kind = self.class.kind
      @line = line
      super(line.positive? ? "YAML parse error at line #{line}: #{message}" : "YAML parse error: #{message}")
    end

    # True when the parser refused the input for crossing a bound rather than for being malformed.
    def limit? = false
  end

  # The text is not valid YAML.
  class SyntaxError < ParseError
    def self.kind = :syntax
  end

  # An alias named an anchor that has not been defined.
  class UndefinedAliasError < ParseError
    def self.kind = :undefined_alias
  end

  # A mapping repeated a key while the policy was +:reject+.
  class DuplicateKeyError < ParseError
    def self.kind = :duplicate_key
  end

  # A stream that should hold exactly one document held none or several.
  class DocumentCountError < ParseError
    def self.kind = :document_count
  end

  # The parser refused the input for crossing one of the bounds in YAMLCamel::Limits.
  class LimitError < ParseError
    def limit? = true
  end

  # The input is larger than Limits#max_input_bytes.
  class InputTooLargeError < LimitError
    def self.kind = :input_too_large
  end

  # Nesting went past Limits#max_depth.
  class DepthExceededError < LimitError
    def self.kind = :depth_exceeded
  end

  # The stream produced more nodes than Limits#max_nodes.
  class TooManyNodesError < LimitError
    def self.kind = :too_many_nodes
  end

  # A scalar was longer than Limits#max_scalar_length.
  class ScalarTooLongError < LimitError
    def self.kind = :scalar_too_long
  end

  # A numeric scalar held more digits than Limits#max_number_digits.
  class NumberTooLongError < LimitError
    def self.kind = :number_too_long
  end

  # More aliases were dereferenced than Limits#max_alias_expansions.
  class TooManyAliasesError < LimitError
    def self.kind = :too_many_aliases
  end

  # The stream held more documents than Limits#max_documents.
  class TooManyDocumentsError < LimitError
    def self.kind = :too_many_documents
  end

  # A resolved tag was longer than Limits#max_tag_length.
  class TagTooLongError < LimitError
    def self.kind = :tag_too_long
  end

  # A failure while writing YAML text.
  #
  # Every case but UnsupportedTypeError and AmbiguousKeyError is a refusal on size, since the value
  # being written is already a tree rather than text that could be malformed.
  class EmitError < Error
    def self.kind = :emit

    attr_reader :kind

    def initialize(message)
      @kind = self.class.kind
      super("YAML emit error: #{message}")
    end
  end

  # Output grew past EmitLimits#max_output_bytes.
  class OutputTooLargeError < EmitError
    def self.kind = :output_too_large
  end

  # The value holds more nodes than EmitLimits#max_nodes.
  class EmitTooManyNodesError < EmitError
    def self.kind = :too_many_nodes
  end

  # The value nests deeper than EmitLimits#max_depth.
  class EmitDepthExceededError < EmitError
    def self.kind = :depth_exceeded
  end

  # The value holds a Ruby object with no YAML 1.2.2 core schema representation.
  class UnsupportedTypeError < EmitError
    def self.kind = :unsupported_type
  end

  # A mapping holds two different keys, such as a Symbol and a String sharing a name, that render to
  # the identical scalar text. Quoting cannot tell them apart, since a plain word and its quoted form
  # resolve to the same core schema value on the way back in, so this is refused rather than handed
  # to a reader as a document that silently drops or rejects one of the two entries.
  class AmbiguousKeyError < EmitError
    def self.kind = :ambiguous_key
  end

  # A failure moving YAML somewhere, rather than reading or writing the YAML itself.
  class TransferError < Error; end

  # The transport could not reach the server at all, which is separate from a server that answered.
  class TransportError < TransferError; end

  # The server answered with a status outside 200 to 299.
  class HTTPStatusError < TransferError
    attr_reader :status, :body

    def initialize(status, body = "")
      @status = status
      @body = body
      super("The server answered with status #{status}.")
    end
  end

  # The server answered with a body that does not claim to be YAML.
  class UnexpectedContentTypeError < TransferError; end

  # The response body is larger than TransferLimits#max_body_bytes.
  class ResponseTooLargeError < TransferError; end

  # The server named a Content-Encoding this library does not handle.
  class UnsupportedContentEncodingError < TransferError; end

  # A body could not be compressed or decompressed.
  class CompressionError < TransferError; end

  # A compressed body expands past TransferLimits#max_inflated_bytes.
  class InflatedTooLargeError < CompressionError; end
end
