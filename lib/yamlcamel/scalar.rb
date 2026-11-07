# frozen_string_literal: true

module YAMLCamel
  # Resolves a plain scalar's text against the YAML 1.2.2 core schema.
  #
  # The core schema leaves +yes+, +no+, +on+ and +off+ as strings, and has no sexagesimal form, so
  # +20:03:20+ stays a string. Both of those are YAML 1.1 behaviour that 1.2 dropped.
  module Scalar
    SPECIAL = {
      "" => nil, "~" => nil, "null" => nil, "Null" => nil, "NULL" => nil,
      "true" => true, "True" => true, "TRUE" => true,
      "false" => false, "False" => false, "FALSE" => false,
      ".inf" => Float::INFINITY, ".Inf" => Float::INFINITY, ".INF" => Float::INFINITY,
      "+.inf" => Float::INFINITY, "+.Inf" => Float::INFINITY, "+.INF" => Float::INFINITY,
      "-.inf" => -Float::INFINITY, "-.Inf" => -Float::INFINITY, "-.INF" => -Float::INFINITY,
      ".nan" => Float::NAN, ".NaN" => Float::NAN, ".NAN" => Float::NAN
    }.freeze

    DECIMAL = /\A[-+]?[0-9]+\z/
    OCTAL = /\A0o[0-7]+\z/
    HEX = /\A0x[0-9a-fA-F]+\z/
    FLOAT = /\A[-+]?(?:\.[0-9]+|[0-9]+(?:\.[0-9]*)?)(?:[eE][-+]?[0-9]+)?\z/

    module_function

    # Resolves plain scalar text to a typed value. Text that matches nothing resolves to a string.
    def resolve(text)
      return SPECIAL[text] if SPECIAL.key?(text)

      integer = parse_integer(text)
      return integer unless integer.nil?

      float = parse_float(text)
      return float unless float.nil?

      text
    end

    # Parses the core schema's integer forms: signed decimal, unsigned +0o+ octal, unsigned +0x+ hex.
    def parse_integer(text)
      case text
      when DECIMAL then Integer(text, 10)
      when OCTAL then Integer(text[2..], 8)
      when HEX then Integer(text[2..], 16)
      end
    end

    # Parses the core schema's float forms. A form with neither a decimal point nor an exponent is an
    # integer as far as resolution is concerned, so it is left to #parse_integer.
    def parse_float(text)
      return nil unless FLOAT.match?(text)
      return nil unless text.include?(".") || text.include?("e") || text.include?("E")

      Float(text, exception: false) || text.to_f
    end

    # True when the text resolves to something other than a string, which is what makes a number's
    # digit count worth bounding before the conversion runs.
    def numeric?(text)
      DECIMAL.match?(text) || OCTAL.match?(text) || HEX.match?(text) || FLOAT.match?(text)
    end
  end
end
