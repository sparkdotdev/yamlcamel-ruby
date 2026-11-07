# frozen_string_literal: true

module YAMLCamel
  # Renders a plain Ruby object tree as block-style YAML text with a two-space indent.
  #
  # Sequences sit at their key's indentation, matching libyaml's conventional output, and scalars are
  # quoted only when a plain scalar would be misread. A mapping whose keys would render to the same
  # text, such as a Symbol and a String sharing a name, is refused rather than written out that way.
  class Emitter
    include Chars

    # Renders one value as a whole document.
    def self.emit(value, sort_keys: false, limits: EmitLimits.default)
      new(sort_keys: sort_keys, limits: limits).emit(value)
    end

    def initialize(sort_keys: false, limits: EmitLimits.default)
      @sort_keys = sort_keys
      @limits = limits
      @budget = EmitBudget.new(@limits)
    end

    def emit(value, document_marker: false)
      out = +""
      append("---\n", out) if document_marker
      case value
      when Hash
        if value.empty?
          @budget.count_node
          append("{}\n", out)
        else
          emit_mapping(value, 0, out)
        end
      when Array
        if value.empty?
          @budget.count_node
          append("[]\n", out)
        else
          emit_sequence(value, 0, out)
        end
      else
        @budget.count_node
        append("#{scalar_text(value)}\n", out)
      end
      out
    end

    protected

    # Sorting a collection key must spend a bounded scratch budget too: #inspect expands
    # aliases without consulting either the byte or node ceiling.
    def flow_sort_text(value)
      out = +""
      emit_flow(value, out)
      out
    end

    private

    def append(text, out)
      @budget.spend(text)
      out << text
    end

    def emit_mapping(members, indent, out)
      @budget.push
      @budget.count_node
      keys = @sort_keys ? members.keys.sort_by { |key| sort_text(key) } : members.keys
      rendered = {}

      keys.each do |key|
        value = members[key]
        next emit_explicit_entry(key, value, indent, out) if collection?(key)

        text = scalar_text(key)
        check_key_collision(key, text, rendered)
        emit_entry("#{pad(indent)}#{text}", value, indent, out)
      end
      @budget.pop
    end

    # A Symbol key and a String key sharing a name render to the identical scalar text no matter how
    # either is quoted, so a reader could never tell the two entries apart. Refused here rather than
    # written out as a mapping that would silently drop or reject one on reload.
    def check_key_collision(key, text, rendered)
      prior = rendered[text]
      if prior
        raise AmbiguousKeyError,
              "#{prior.inspect} and #{key.inspect} both render as the mapping key #{text}."
      end
      rendered[text] = key
    end

    # A key that is itself a collection has no place before a ':', so it is written the long way, with
    # the key in flow style after a '?' and the value under a ':' of its own.
    def emit_explicit_entry(key, value, indent, out)
      @budget.count_node
      append("#{pad(indent)}? ", out)
      emit_flow(key, out)
      append("\n", out)
      emit_entry("#{pad(indent)}", value, indent, out)
    end

    # Writes ": value" after a lead that already holds the indentation and the key.
    def emit_entry(lead, value, indent, out)
      case value
      when Hash
        if value.empty?
          @budget.count_node
          append("#{lead}: {}\n", out)
        else
          append("#{lead}:\n", out)
          emit_mapping(value, indent + 2, out)
        end
      when Array
        if value.empty?
          @budget.count_node
          append("#{lead}: []\n", out)
        else
          append("#{lead}:\n", out)
          emit_sequence(value, indent, out)
        end
      else
        @budget.count_node
        append("#{lead}: #{scalar_text(value)}\n", out)
      end
    end

    def emit_sequence(items, indent, out)
      @budget.push
      @budget.count_node

      items.each do |item|
        case item
        when Hash
          if item.empty?
            @budget.count_node
            append("#{pad(indent)}- {}\n", out)
          else
            # The first key shares the dash line. Written straight into the buffer and then patched,
            # rather than built to the side and copied in, so a deeply nested value is not recopied
            # once per level on the way out.
            start = out.bytesize
            emit_mapping(item, indent + 2, out)
            out.bytesplice(start, indent + 2, "#{pad(indent)}- ")
          end
        when Array
          if item.empty?
            @budget.count_node
            append("#{pad(indent)}- []\n", out)
          else
            append("#{pad(indent)}-\n", out)
            emit_sequence(item, indent + 2, out)
          end
        else
          @budget.count_node
          append("#{pad(indent)}- #{scalar_text(item)}\n", out)
        end
      end
      @budget.pop
    end

    def collection?(value) = value.is_a?(Hash) || value.is_a?(Array)

    # A total order over keys of mixed types, since Ruby has no comparison between a String and an
    # Integer and sorting is a convenience rather than part of the value.
    def sort_text(key)
      case key
      when String then key
      when Symbol then key.name
      when Hash, Array
        @sort_emitter ||= self.class.new(sort_keys: false, limits: @limits)
        @sort_emitter.flow_sort_text(key)
      else key.to_s
      end
    end

    # MARK: scalars

    def scalar_text(value)
      case value
      when nil then "null"
      when true then "true"
      when false then "false"
      when Integer then value.to_s
      when Float then float_text(value)
      when String then string_text(value)
      when Symbol then string_text(value.name)
      when Hash, Array
        raise UnsupportedTypeError, "A collection scalar must be emitted in flow style."
      else
        raise UnsupportedTypeError, "#{value.class} has no YAML 1.2.2 core schema representation."
      end
    end

    def float_text(value)
      return ".nan" if value.nan?
      return ".inf" if value == Float::INFINITY
      return "-.inf" if value == -Float::INFINITY

      value.to_s
    end

    # A whole value in flow style, which is what an explicit key is written in.
    def emit_flow(value, out)
      @budget.push
      @budget.count_node
      case value
      when Hash
        append("{", out)
        rendered = {}
        value.each_with_index do |(key, child), index|
          append(", ", out) unless index.zero?
          check_key_collision(key, scalar_text(key), rendered) unless collection?(key)
          emit_flow(key, out)
          append(": ", out)
          emit_flow(child, out)
        end
        append("}", out)
      when Array
        append("[", out)
        value.each_with_index do |item, index|
          append(", ", out) unless index.zero?
          emit_flow(item, out)
        end
        append("]", out)
      else
        append(scalar_text(value), out)
      end
    ensure
      @budget.pop
    end

    def string_text(text)
      text = utf8(text)
      needs_quoting?(text) ? double_quoted(text) : text
    end

    # A YAML stream is UTF-8. Every String the parser hands back already reads as UTF-8; one the
    # caller built may not, and is refused here rather than silently rewritten.
    def utf8(text)
      return text if text.encoding == Encoding::UTF_8 && text.valid_encoding?

      converted =
        if text.encoding == Encoding::ASCII_8BIT
          # Binary claims no encoding at all, so it reads as UTF-8 whenever the bytes happen to be.
          text.dup.force_encoding(Encoding::UTF_8)
        elsif text.valid_encoding?
          begin
            text.encode(Encoding::UTF_8)
          rescue EncodingError
            nil
          end
        end
      return converted if converted&.valid_encoding?

      raise UnsupportedTypeError,
            "a String holding bytes that do not read as UTF-8 has no YAML 1.2.2 representation."
    end

    def needs_quoting?(text)
      return true if text.empty?

      # A plain scalar that would read back as null, a bool or a number has to be quoted.
      resolved = Scalar.resolve(text)
      return true unless resolved.is_a?(String) && resolved == text
      return true if text.start_with?("---", "...")
      return true if text.start_with?(" ", "\t") || text.end_with?(" ", "\t")

      points = text.codepoints
      points.each_with_index do |c, index|
        case c
        when LF, CR, TAB, NEL, LINE_SEPARATOR, PARAGRAPH_SEPARATOR, BOM,
             DQUOTE, SQUOTE, LBRACKET, RBRACKET, LBRACE, RBRACE, COMMA, HASH, AMPERSAND, STAR,
             BANG, PIPE, GREATER, PERCENT, AT, BACKTICK
          return true
        when COLON
          nxt = points[index + 1]
          # A ':' in front is the value indicator to a flow mapping, which reads it before it looks
          # for a key at all, so a scalar starting with one is quoted whatever comes after it. The
          # emitter writes a collection key in flow style, which is how a plain scalar gets there.
          return true if index.zero?
          return true if nxt.nil? || nxt == SPACE || nxt == TAB
        when DASH, QUESTION
          nxt = points[index + 1]
          return true if index.zero? && (nxt.nil? || nxt == SPACE || nxt == TAB)
        else
          return true if c < 0x20 || (0x7F..0x9F).cover?(c) || c == 0xFFFE || c == 0xFFFF
        end
      end
      false
    end

    DOUBLE_QUOTE_ESCAPES = {
      "\\" => "\\\\", "\"" => "\\\"", "\n" => "\\n", "\t" => "\\t", "\r" => "\\r",
      "\u0085" => "\\N", "\u00A0" => "\\_", "\u2028" => "\\L", "\u2029" => "\\P",
      "\uFEFF" => "\\uFEFF"
    }.freeze

    def double_quoted(text)
      out = +'"'
      text.each_char do |char|
        escaped = DOUBLE_QUOTE_ESCAPES[char]
        if escaped
          out << escaped
        elsif char.ord < 0x20 || char.ord == DEL
          out << format("\\x%02X", char.ord)
        elsif (0x80..0x9F).cover?(char.ord) || char.ord == 0xFFFE || char.ord == 0xFFFF
          out << format("\\u%04X", char.ord)
        else
          out << char
        end
      end
      out << '"'
    end

    def pad(width) = " " * width
  end

  # Carries the emitter's running totals, so a nested buffer spends the same budget as the one it
  # will be folded into.
  class EmitBudget
    def initialize(limits)
      @limits = limits
      @bytes = 0
      @nodes = 0
      @depth = 0
      @depth_ceiling = limits.depth_ceiling
    end

    def spend(text)
      @bytes += text.bytesize
      return if @bytes <= @limits.max_output_bytes

      raise OutputTooLargeError, "Output grew past the #{@limits.max_output_bytes} byte limit."
    end

    def count_node
      @nodes += 1
      return if @nodes <= @limits.max_nodes

      raise EmitTooManyNodesError, "Value holds more than #{@limits.max_nodes} nodes."
    end

    def push
      @depth += 1
      return if @depth <= @depth_ceiling

      raise EmitDepthExceededError, "Value nests deeper than the limit of #{@depth_ceiling}."
    end

    def pop
      @depth -= 1
    end
  end
end
