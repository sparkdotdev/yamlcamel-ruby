# frozen_string_literal: true

module YAMLCamel
  # The codepoints the grammar switches on.
  #
  # The reader works over an array of codepoints rather than an array of one-character strings: a
  # string per character costs about forty bytes each, which a sixteen megabyte input cannot afford.
  module Chars
    TAB = 0x09
    LF = 0x0A
    CR = 0x0D
    SPACE = 0x20
    BANG = 0x21
    DQUOTE = 0x22
    HASH = 0x23
    PERCENT = 0x25
    AMPERSAND = 0x26
    SQUOTE = 0x27
    STAR = 0x2A
    PLUS = 0x2B
    COMMA = 0x2C
    DASH = 0x2D
    DOT = 0x2E
    SLASH = 0x2F
    ZERO = 0x30
    NINE = 0x39
    COLON = 0x3A
    LESS = 0x3C
    GREATER = 0x3E
    QUESTION = 0x3F
    AT = 0x40
    LBRACKET = 0x5B
    BACKSLASH = 0x5C
    RBRACKET = 0x5D
    BACKTICK = 0x60
    LBRACE = 0x7B
    PIPE = 0x7C
    RBRACE = 0x7D
    TILDE = 0x7E
    DEL = 0x7F
    NEL = 0x85
    NBSP = 0xA0
    LINE_SEPARATOR = 0x2028
    PARAGRAPH_SEPARATOR = 0x2029
    BOM = 0xFEFF

    # The highest codepoint Unicode defines, and the surrogate range no scalar may hold.
    MAX_CODEPOINT = 0x10FFFF
    SURROGATES = (0xD800..0xDFFF).freeze
  end
end
