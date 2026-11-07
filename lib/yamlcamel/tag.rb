# frozen_string_literal: true

module YAMLCamel
  # Applies YAML tags and the 1.2.2 core schema to a scalar or a collection.
  #
  # A tag the core schema does not define is carried no further than resolution: the value keeps the
  # type the core schema would have given it, so an unknown tag annotates rather than fails.
  module Tag
    PREFIX = "tag:yaml.org,2002:"
    NULL = "#{PREFIX}null"
    BOOL = "#{PREFIX}bool"
    INT = "#{PREFIX}int"
    FLOAT = "#{PREFIX}float"
    STR = "#{PREFIX}str"
    SEQ = "#{PREFIX}seq"
    MAP = "#{PREFIX}map"

    DEFAULT_HANDLES = { "!" => "!", "!!" => PREFIX }.freeze

    module_function

    # Resolves a scalar. Pass the text, whether it was written plain, and the tag the document
    # carried. Raises SyntaxError when an explicit tag does not fit the text.
    def resolve_scalar(text, plain:, tag:, line:)
      return plain ? Scalar.resolve(text) : text if tag.nil?

      case tag
      when "!", STR
        text
      when NULL
        mismatch(text, "null", line) unless Scalar.resolve(text).nil?
        nil
      when BOOL
        value = Scalar.resolve(text)
        mismatch(text, "bool", line) unless value == true || value == false
        value
      when INT
        Scalar.parse_integer(text) || mismatch(text, "int", line)
      when FLOAT
        float_value(text) || mismatch(text, "float", line)
      when SEQ, MAP
        raise SyntaxError.new("A scalar cannot carry the tag #{tag}.", line: line)
      else
        plain ? Scalar.resolve(text) : text
      end
    end

    # Resolves a collection. Raises SyntaxError when the tag names the other kind of collection or a
    # scalar type.
    def resolve_collection(value, tag:, line:)
      return value if tag.nil? || tag == "!"

      case tag
      when SEQ
        raise SyntaxError.new("A mapping cannot carry the tag #{tag}.", line: line) unless value.is_a?(Array)

        value
      when MAP
        raise SyntaxError.new("A sequence cannot carry the tag #{tag}.", line: line) unless value.is_a?(Hash)

        value
      when STR, INT, FLOAT, BOOL, NULL
        raise SyntaxError.new("A collection cannot carry the tag #{tag}.", line: line)
      else
        value
      end
    end

    def float_value(text)
      resolved = Scalar.resolve(text)
      return resolved if resolved.is_a?(Float)

      # An explicit float tag widens an integer literal, which plain resolution would have left an
      # Integer.
      resolved.is_a?(Integer) ? resolved.to_f : Scalar.parse_float(text)
    end

    def mismatch(text, kind, line)
      raise SyntaxError.new("Value '#{text}' is tagged #{kind} but does not read as one.", line: line)
    end
  end
end
