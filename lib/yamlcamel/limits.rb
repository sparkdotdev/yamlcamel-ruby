# frozen_string_literal: true

module YAMLCamel
  # Bounds the parser applies while reading, so hostile input is refused rather than absorbed.
  #
  # Every bound is checked during parsing rather than after it, because a limit that only applies to
  # a finished value cannot stop the work that produced it.
  class Limits
    # The deepest nesting the parser will ever attempt, whatever a caller asks for. Parsing is
    # recursive descent, so nesting past the interpreter's own stack raises SystemStackError; this
    # sits well below where that starts.
    MAX_SUPPORTED_DEPTH = 256

    # How a mapping with a repeated key is handled.
    DUPLICATE_KEY_POLICIES = %i[reject first_wins last_wins].freeze

    attr_reader :max_input_bytes, :max_depth, :max_nodes, :max_scalar_length, :max_number_digits,
                :max_alias_expansions, :max_documents, :max_tag_length, :duplicate_keys

    # Creates a limit set. Every argument defaults to the value Limits.default uses.
    def initialize(max_input_bytes: 16 << 20,
                   max_depth: MAX_SUPPORTED_DEPTH,
                   max_nodes: 2_000_000,
                   max_scalar_length: 4 << 20,
                   max_number_digits: 4096,
                   max_alias_expansions: 10_000,
                   max_documents: 1024,
                   max_tag_length: 4096,
                   duplicate_keys: :reject)
      unless DUPLICATE_KEY_POLICIES.include?(duplicate_keys)
        raise ArgumentError, "duplicate_keys must be one of #{DUPLICATE_KEY_POLICIES.join(", ")}"
      end

      @max_input_bytes = max_input_bytes
      @max_depth = max_depth
      @max_nodes = max_nodes
      @max_scalar_length = max_scalar_length
      @max_number_digits = max_number_digits
      @max_alias_expansions = max_alias_expansions
      @max_documents = max_documents
      @max_tag_length = max_tag_length
      @duplicate_keys = duplicate_keys
      freeze
    end

    # A copy with the named bounds replaced.
    def with(**overrides)
      Limits.new(**to_h.merge(overrides))
    end

    def to_h
      { max_input_bytes: @max_input_bytes, max_depth: @max_depth, max_nodes: @max_nodes,
        max_scalar_length: @max_scalar_length, max_number_digits: @max_number_digits,
        max_alias_expansions: @max_alias_expansions, max_documents: @max_documents,
        max_tag_length: @max_tag_length, duplicate_keys: @duplicate_keys }
    end

    def ==(other) = other.is_a?(Limits) && to_h == other.to_h
    alias eql? ==

    def hash = to_h.hash

    # The nesting the parser will actually apply, since a caller cannot raise the ceiling.
    def depth_ceiling = @max_depth < MAX_SUPPORTED_DEPTH ? @max_depth : MAX_SUPPORTED_DEPTH

    # The limits every entry point uses when the caller does not pass its own.
    def self.default = DEFAULT

    # Limits with no ceiling worth speaking of, for input you produced yourself. Nesting stays
    # bounded, because the alternative is a SystemStackError no caller asked for.
    def self.permissive = PERMISSIVE

    DEFAULT = new
    PERMISSIVE = new(max_input_bytes: Float::INFINITY,
                     max_depth: MAX_SUPPORTED_DEPTH,
                     max_nodes: Float::INFINITY,
                     max_scalar_length: Float::INFINITY,
                     max_number_digits: Float::INFINITY,
                     max_alias_expansions: Float::INFINITY,
                     max_documents: Float::INFINITY,
                     max_tag_length: Float::INFINITY,
                     duplicate_keys: :last_wins)
  end

  # Bounds the emitter applies while writing.
  #
  # Parsing and emitting do not cost the same. An alias lets the parser accept a large tree cheaply,
  # because what the alias names is shared rather than copied, and the emitter has to write every
  # copy out in full. These bounds are what stops a document the parser was right to accept from
  # becoming an enormous amount of text.
  class EmitLimits
    attr_reader :max_output_bytes, :max_nodes, :max_depth

    def initialize(max_output_bytes: 16 << 20,
                   max_nodes: 2_000_000,
                   max_depth: Limits::MAX_SUPPORTED_DEPTH)
      @max_output_bytes = max_output_bytes
      @max_nodes = max_nodes
      @max_depth = max_depth
      freeze
    end

    def with(**overrides)
      EmitLimits.new(**to_h.merge(overrides))
    end

    def to_h
      { max_output_bytes: @max_output_bytes, max_nodes: @max_nodes, max_depth: @max_depth }
    end

    def ==(other) = other.is_a?(EmitLimits) && to_h == other.to_h
    alias eql? ==

    def hash = to_h.hash

    def depth_ceiling = @max_depth < Limits::MAX_SUPPORTED_DEPTH ? @max_depth : Limits::MAX_SUPPORTED_DEPTH

    # The limits every emit uses when the caller does not pass its own. The byte bound matches
    # Limits#max_input_bytes, so text written under the default limits reads back under them too.
    def self.default = DEFAULT

    # Limits with no ceiling worth speaking of, for values you built yourself.
    def self.permissive = PERMISSIVE

    DEFAULT = new
    PERMISSIVE = new(max_output_bytes: Float::INFINITY, max_nodes: Float::INFINITY)
  end
end
