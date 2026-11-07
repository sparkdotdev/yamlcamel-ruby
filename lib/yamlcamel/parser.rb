# frozen_string_literal: true

module YAMLCamel
  # Parses YAML 1.2.2 text into plain Ruby objects.
  #
  # The reader below is recursive descent over unicode codepoints, shaped to follow the spec's own
  # productions, so an indentation rule in the spec has one place here that implements it.
  module Parser
    module_function

    # Parses a stream that holds exactly one document. Returns the document's value, or nil for an
    # empty stream. Raises DocumentCountError when the stream holds more than one.
    def parse(input, limits: Limits.default)
      documents = parse_stream(input, limits: limits)
      return nil if documents.empty?
      raise DocumentCountError, "Expected one document but the stream holds #{documents.size}." unless
        documents.size == 1

      documents.first
    end

    # Parses every document in a stream and returns one value per document, in order.
    def parse_stream(input, limits: Limits.default)
      Reader.new(input, limits: limits).parse_stream
    end
  end

  # The totals one parse spends, held apart from the reader so several parses can draw on one
  # ceiling.
  class Budget
    attr_accessor :nodes, :aliases

    def initialize
      @nodes = 0
      @aliases = 0
    end
  end

  # Reads one stream. Created per parse, never shared.
  class Reader
    include Chars

    # The properties that may precede any node.
    Props = Struct.new(:anchor, :tag) do
      def empty? = anchor.nil? && tag.nil?
    end

    NO_PROPS = Props.new(nil, nil).freeze

    # Tags that never send a scalar's text through numeric parsing, whatever the text looks like.
    NON_NUMERIC_TAGS = ["!", Tag::STR, Tag::SEQ, Tag::MAP].freeze

    # Of those, the ones that also never raise a mismatch against the text they tag, so a probe that
    # only needs to know whether a ':' follows can carry either safely without changing its answer.
    PROBE_SAFE_TAGS = ["!", Tag::STR].freeze

    # Tags whose resolution always tries to read the text as a number, plain or not.
    NUMERIC_TAGS = [Tag::NULL, Tag::BOOL, Tag::INT, Tag::FLOAT].freeze

    # What an anchor holds, and how much of the budget an alias to it costs.
    Anchor = Struct.new(:value, :nodes, :depth)

    def initialize(input, limits: Limits.default, budget: nil)
      @limits = limits
      @budget = budget || Budget.new
      @depth = 0
      @deepest = 0
      @depth_ceiling = limits.depth_ceiling
      @anchors = {}
      @tag_handles = Tag::DEFAULT_HANDLES.dup
      @document_handles = []
      @yaml_directive = false
      @i = 0
      @line = 1
      @col = 0
      @src = prepare(input)
    end

    def parse_stream
      documents = []
      loop do
        skip_to_content
        break if eof?

        saw_directive = false
        while current == PERCENT
          parse_directive
          saw_directive = true
          skip_to_content
        end

        explicit = false
        if document_start_marker?
          advance_n(3)
          explicit = true
        elsif saw_directive
          raise syntax("A directive has to be followed by a '---' marker.")
        end

        if document_end_marker?
          consume_document_end
          # A '---' with nothing after it is an explicit empty document. A bare '...' with no '---'
          # of its own is a leftover end marker between documents and starts nothing.
          append_document(documents, nil) if explicit
          reset_document_state
          next
        end

        value =
          if explicit
            parse_node_value(-1, :document_root)
          else
            skip_to_content
            break if eof?

            parse_node_here(@col, -1, NO_PROPS)
          end
        append_document(documents, value)

        save = mark
        skip_to_content
        break if eof?

        if document_end_marker?
          consume_document_end
          reset_document_state
          next
        end
        if document_start_marker?
          reset_document_state
          next
        end
        reset(save)
        raise syntax("Content after the end of a document needs a '---' or '...' marker.")
      end
      documents
    end

    private

    # Reads the input, holds it to the byte bound, and returns it as codepoints with line breaks
    # normalised.
    def prepare(input)
      text = read_input(input)
      text = to_utf8(text)
      if text.match?(/[\x00-\x08\x0B\x0C\x0E-\x1F]/)
        raise syntax("Input contains a forbidden control character.")
      end
      unless text.bytesize <= @limits.max_input_bytes
        raise InputTooLargeError,
              "Input is #{text.bytesize} bytes, over the #{@limits.max_input_bytes} byte limit."
      end

      # YAML 1.2 line breaks are LF and CR, and both normalise to LF everywhere they are content.
      text = text.gsub(/\r\n?/, "\n") if text.include?("\r")
      points = text.codepoints
      points
    end

    def read_input(input)
      return input unless input.respond_to?(:read)

      # Bounded rather than a plain read, since reading a hostile stream whole to measure it
      # afterwards is the cost the bound exists to refuse.
      limit = @limits.max_input_bytes
      return input.read.to_s unless limit.is_a?(Integer)

      text = input.read(limit + 1).to_s
      raise InputTooLargeError, "Input is over the #{limit} byte limit." if text.bytesize > limit

      text
    end

    def to_utf8(text)
      text = text.to_s
      text = text.dup.force_encoding(Encoding::UTF_8) if text.encoding == Encoding::ASCII_8BIT
      text = text.encode(Encoding::UTF_8) unless
        text.encoding == Encoding::UTF_8
      raise syntax("Input is not valid UTF-8.") unless text.valid_encoding?

      text
    rescue EncodingError
      raise syntax("Input is not valid UTF-8.")
    end

    # MARK: cursor

    def current = @src[@i]

    def at(offset) = @src[@i + offset]

    def eof? = @i >= @src.length

    def advance
      c = @src[@i]
      return if c.nil?

      if c == LF
        @line += 1
        @col = 0
      else
        @col += 1
      end
      @i += 1
    end

    def advance_n(count)
      count.times { advance }
    end

    def mark = [@i, @line, @col]

    def reset(saved)
      @i, @line, @col = saved
    end

    def slice_text(from, to)
      return "" if to <= from

      @src[from...to].pack("U*")
    end

    # MARK: character predicates

    def blank?(c) = c == SPACE || c == TAB

    def blank_or_break?(c) = c.nil? || c == SPACE || c == TAB || c == LF

    def digit?(c) = !c.nil? && c >= ZERO && c <= NINE

    # Skips spaces and tabs, and reports whether a tab was among them, since a tab is separation
    # everywhere the grammar allows white space but never counts as indentation.
    def skip_blanks
      source = @src
      index = @i
      tab = false
      while (c = source[index]) == SPACE || c == TAB
        tab ||= c == TAB
        index += 1
        @col += 1
      end
      @i = index
      tab
    end

    def skip_to_end_of_line
      source = @src
      index = @i
      while (c = source[index]) && c != LF
        index += 1
        @col += 1
      end
      check_printable(slice_text(@i, index))
      @i = index
    end

    # Skips a line's leading spaces, which are its indentation. A tab is left where it is: the spec
    # builds indentation out of spaces alone, so a tab is white space between tokens, not
    # indentation itself.
    def skip_indentation
      count = 0
      count += 1 while @src[@i + count] == SPACE
      @i += count
      @col += count
      count
    end

    # True when nothing but white space, a comment or the end of the line follows the tab the cursor
    # sits on, which makes the whole run white space rather than a line's indentation.
    def blank_after_tabs?
      return false unless current == TAB

      index = @i
      index += 1 while (c = @src[index]) == SPACE || c == TAB
      c = @src[index]
      c.nil? || c == LF || c == HASH
    end

    # Moves to the first non-space character of the next line that holds content, skipping blank and
    # comment lines. Leaves the column holding that line's indentation.
    def skip_to_content
      loop do
        if @col.zero?
          # A byte order mark may open any document in a stream, not only the first, since each one
          # can come from its own source. Gated on the column rather than checked once before the
          # loop, so a mark reached after skipping blank lines is still caught.
          @i += 1 if current == BOM
          skip_indentation
          skip_blanks if blank_after_tabs?
        else
          skip_blanks
        end
        # A comment needs a space, a tab or a line break before it. That is always true at the very
        # start of the text, since there is nothing there for it to be glued onto.
        skip_to_end_of_line if current == HASH && (@i.zero? || blank?(@src[@i - 1]) || @src[@i - 1] == LF)
        if current == LF
          advance
          next
        end
        return
      end
    end

    # Skips the line breaks and white space between two lines of one scalar. Returns how many breaks
    # there were and the indentation the line the cursor lands on begins at.
    def skip_folded_breaks
      breaks = 0
      indent = @col
      loop do
        if @col.zero?
          indent = skip_indentation
          skip_blanks
        else
          skip_blanks
        end
        if current == LF
          advance
          breaks += 1
          next
        end
        break
      end
      [breaks, indent]
    end

    def document_start_marker?
      @col.zero? && at(0) == DASH && at(1) == DASH && at(2) == DASH && blank_or_break?(at(3))
    end

    def document_end_marker?
      @col.zero? && at(0) == DOT && at(1) == DOT && at(2) == DOT && blank_or_break?(at(3))
    end

    def document_boundary? = document_start_marker? || document_end_marker?

    def sequence_entry? = current == DASH && blank_or_break?(at(1))

    def explicit_key? = current == QUESTION && blank_or_break?(at(1))

    def explicit_value? = current == COLON && blank_or_break?(at(1))

    # MARK: budgets

    # Refused before the counter moves, so the level a reader never entered is not left charged
    # against it. The collection parsers call this ahead of the block whose ensure would pop it.
    def push_depth
      if @depth >= @depth_ceiling
        raise DepthExceededError.new("Nesting is deeper than the limit of #{@depth_ceiling}.", line: @line)
      end

      @depth += 1
      @deepest = @depth if @depth > @deepest
    end

    def pop_depth
      @depth -= 1
    end

    # Opens a collection and starts measuring it, since an anchor needs to know how many nodes and
    # levels the value behind it holds. Walking the finished value on every anchor would turn a
    # deeply anchored document into quadratic work; the running totals give the same answer for free.
    def enter_collection
      push_depth
      frame = [@budget.nodes, @deepest]
      @deepest = @depth
      frame
    end

    # Closes a collection and returns how many nodes and levels it came to.
    def leave_collection(frame)
      start_nodes, outer_deepest = frame
      shape = [@budget.nodes - start_nodes, @deepest - @depth + 2]
      pop_depth
      @deepest = outer_deepest if outer_deepest > @deepest
      shape
    end

    def count_node(count = 1)
      @budget.nodes += count
      return if @budget.nodes <= @limits.max_nodes

      raise TooManyNodesError.new("Stream produces more than #{@limits.max_nodes} nodes.", line: @line)
    end

    def check_scalar_length(length)
      return if length <= @limits.max_scalar_length

      raise ScalarTooLongError.new("Scalar is longer than the limit of #{@limits.max_scalar_length}.",
                                   line: @line)
    end

    # Bounds the cost of turning a numeric literal into a number, which is superlinear in its own
    # digit count and so is not covered by the scalar bound alone.
    def check_number_digits(text)
      return if text.length <= @limits.max_number_digits
      return unless Scalar.numeric?(text)

      raise NumberTooLongError.new("Number holds more than #{@limits.max_number_digits} digits.",
                                   line: @line)
    end

    def check_printable(text)
      if text.codepoints.any? { |c| ((0x7F..0x9F).cover?(c) && c != NEL) || c == 0xFFFE || c == 0xFFFF }
        raise syntax("Non-printable characters must be quoted or escaped.")
      end
    end

    def leading_spaces
      start = @i
      start -= 1 while start.positive? && @src[start - 1] != LF
      finish = start
      finish += 1 while @src[finish] == SPACE
      finish - start
    end

    def indentation_has_tab?
      index = @i
      index -= 1 while index.positive? && @src[index - 1] != LF
      index += 1 if @src[index] == BOM
      tab = false
      while blank?(@src[index])
        tab ||= @src[index] == TAB
        index += 1
      end
      tab
    end

    def syntax(message) = SyntaxError.new(message, line: @line)

    # Nothing but a comment may follow a '...' on its own line.
    def consume_document_end
      advance_n(3)
      skip_blanks
      return if eof? || current == LF || current == HASH

      raise syntax("A '...' marker ends its line.")
    end

    def append_document(documents, value)
      unless documents.size < @limits.max_documents
        raise TooManyDocumentsError.new("Stream holds more than #{@limits.max_documents} documents.",
                                        line: @line)
      end

      documents << value
    end

    # Anchors and tag handles do not cross a document boundary. The node and alias totals do,
    # deliberately: they bound the work one input can cause, and a stream is one input however many
    # '---' markers it holds.
    def reset_document_state
      @anchors.clear
      @tag_handles = Tag::DEFAULT_HANDLES.dup
      @document_handles.clear
      @yaml_directive = false
    end

    # MARK: directives

    def parse_directive
      advance
      name = read_directive_word
      skip_blanks
      args = []
      while (c = current) && c != LF && c != HASH
        arg = read_directive_word
        args << arg unless arg.empty?
        skip_blanks
      end

      check_printable(name)
      args.each { |arg| check_printable(arg) }
      case name
      when "YAML" then apply_yaml_directive(args)
      when "TAG" then apply_tag_directive(args)
      end
      skip_to_end_of_line
      advance if current == LF
    end

    # A directive's words end at white space alone: a '#' glued onto one is part of it, since a
    # comment needs white space before it.
    def read_directive_word
      start = @i
      source = @src
      index = @i
      index += 1 while (c = source[index]) && !blank_or_break?(c)
      @col += index - @i
      @i = index
      slice_text(start, index)
    end

    def apply_yaml_directive(args)
      raise syntax("A document has at most one %YAML directive.") if @yaml_directive

      @yaml_directive = true
      raise syntax("A %YAML directive takes exactly one version.") unless args.size == 1
      unless /\A1\.\d+\z/.match?(args[0])
        raise syntax("This library reads YAML 1.x, and the stream declares #{args[0]}.")
      end
    end

    def apply_tag_directive(args)
      raise syntax("A %TAG directive needs a handle and a prefix.") unless args.size == 2

      handle, prefix = args
      unless handle == "!" || handle == "!!" || /\A!.+!\z/.match?(handle)
        raise syntax("Tag handle #{handle} is not a handle a %TAG directive can define.")
      end
      raise syntax("A document defines the tag handle #{handle} twice.") if @document_handles.include?(handle)

      @document_handles << handle
      @tag_handles[handle] = prefix
    end

    # MARK: node properties

    # Reads the '&anchor' and '!tag' that may precede a node, in either order.
    def parse_properties(starting = NO_PROPS)
      props = Props.new(starting.anchor, starting.tag)
      loop do
        if current == AMPERSAND && props.anchor.nil?
          advance
          props.anchor = read_name("anchor")
        elsif current == BANG && props.tag.nil?
          props.tag = read_tag
        else
          break
        end

        save = mark
        skip_blanks
        next if current == AMPERSAND || current == BANG

        reset(save)
        break
      end
      props
    end

    def read_tag
      advance
      return bounded_tag(read_verbatim_tag) if current == LESS

      first = read_tag_word(stop_at_bang: true)
      if current == BANG
        advance
        handle = "!#{first}!"
        suffix = read_tag_word(stop_at_bang: false)
        prefix = @tag_handles[handle]
        raise syntax("Tag handle #{handle} has no %TAG directive.") if prefix.nil?

        # Checked on the raw pieces before joining or percent-decoding them, since a handle's prefix
        # comes from one directive but a use of it can repeat any number of times, and building the
        # joined string first would pay for every repeat before the length was ever looked at.
        raise_tag_too_long if prefix.bytesize + suffix.bytesize > @limits.max_tag_length

        return prefix + percent_decoded(suffix)
      end
      return "!" if first.empty?

      # Checked the same way as the named-handle form above, since the primary handle's own prefix
      # can also be redefined once by a %TAG ! directive and then reused by any number of shorthand
      # tags, the same shape of cost.
      prefix = @tag_handles["!"] || "!"
      raise_tag_too_long if prefix.bytesize + first.bytesize > @limits.max_tag_length

      prefix + percent_decoded(first)
    end

    def bounded_tag(tag)
      check_printable(tag)
      raise_tag_too_long if tag.bytesize > @limits.max_tag_length

      tag
    end

    def raise_tag_too_long
      raise TagTooLongError, "A tag is over the #{@limits.max_tag_length} byte limit."
    end

    def read_verbatim_tag
      advance
      start = @i
      advance while (c = current) && c != GREATER
      body = slice_text(start, @i)
      raise syntax("A verbatim tag needs a closing '>'.") unless current == GREATER

      advance
      raise syntax("A verbatim tag needs a body.") if body.empty?

      body
    end

    def read_tag_word(stop_at_bang:)
      start = @i
      source = @src
      index = @i
      while (c = source[index]) && !blank_or_break?(c) &&
            c != COMMA && c != LBRACKET && c != RBRACKET && c != LBRACE && c != RBRACE &&
            !(stop_at_bang && c == BANG)
        index += 1
      end
      @col += index - @i
      @i = index
      text = slice_text(start, index)
      check_printable(text)
      text
    end

    def percent_decoded(text)
      return text unless text.include?("%")

      decoded = text.gsub(/(?:%[0-9A-Fa-f]{2})+/) do |run|
        [run.delete("%")].pack("H*").force_encoding(Encoding::UTF_8)
      end
      decoded.valid_encoding? ? decoded : decoded.scrub
    end

    def read_name(what)
      start = @i
      source = @src
      index = @i
      while (c = source[index]) && !blank_or_break?(c) &&
            c != COMMA && c != LBRACKET && c != RBRACKET && c != LBRACE && c != RBRACE
        index += 1
      end
      @col += index - @i
      @i = index
      name = slice_text(start, index)
      check_printable(name)
      raise syntax("An #{what} needs a name.") if name.empty?

      name
    end

    # MARK: values

    # True where the spec reaches a node through s-l+block-indented, letting a collection start on
    # the same line as the indicator that introduced it: a sequence entry's '-', or an explicit
    # key's '?' or ':'. A mapping value or the document root instead needs its own line.
    def allows_compact_collection?(parent)
      parent == :sequence_item || parent == :explicit_key || parent == :explicit_value
    end

    # True where a block sequence may sit at the same indentation as its parent rather than deeper.
    # Does not extend to a sequence item, since a sequence nested directly in another sequence still
    # needs the extra indentation to tell the two apart.
    def allows_zero_indent_sequence?(parent)
      parent == :mapping_value || parent == :explicit_key || parent == :explicit_value
    end

    # Parses the node that follows a parent's indicator, where the parent sits at parent_indent.
    def parse_node_value(parent_indent, parent)
      tab = skip_blanks
      props = NO_PROPS
      if property_start?
        props = parse_properties
        tab = skip_blanks || tab
      end

      if current == HASH || current == LF || eof?
        skip_to_end_of_line if current == HASH
        advance if current == LF

        save = mark
        skip_to_content
        if eof? || document_boundary?
          reset(save)
          return build_scalar("", plain: true, props: props)
        end

        indent = @col
        return parse_node_here(indent, parent_indent, props, parent: parent) if indent > parent_indent
        if indent == parent_indent && allows_zero_indent_sequence?(parent) && sequence_entry?
          return parse_block_sequence(indent, props)
        end

        reset(save)
        return build_scalar("", plain: true, props: props)
      end

      if current == PIPE || current == GREATER
        return build_scalar(parse_block_scalar(parent_indent), plain: false, props: props, block: true)
      end

      indent = @col
      if allows_compact_collection?(parent)
        if sequence_entry?
          # A collection written on the indicator's own line is still indented by what precedes it,
          # and a tab cannot be indentation. Properties cannot precede it at all, since the grammar
          # puts a line break between them and the collection they belong to.
          raise syntax("A tab cannot indent a compact collection.") if tab
          raise syntax("A block sequence cannot start on the line its properties are on.") unless props.empty?

          return parse_block_sequence(indent, props)
        end
        if starts_block_mapping?(indent, tag: props.tag)
          raise syntax("A tab cannot indent a compact collection.") if tab

          return parse_block_mapping(indent, props, props.empty? ? nil : props)
        end
      end
      parse_flow_node(parent_indent, :flow_out, props).first
    end

    def property_start? = current == AMPERSAND || current == BANG

    # Parses the node that begins at the cursor, which sits at the first content character of a line
    # indented at indent.
    def parse_node_here(indent, parent_indent, props, parent: :document_root, props_on_key_line: false)
      # This node has already cleared the indentation it needed, so a tab before its content is
      # white space between tokens. A block collection is the exception: its own entries are
      # measured from a column, and a tab does not make one.
      tab = skip_blanks || indentation_has_tab?
      if tab && (sequence_entry? || explicit_key? || explicit_value?)
        raise syntax("A tab cannot indent a block collection.")
      end

      # An anchor and a tag may each sit on their own line, more indented than the parent, ahead of
      # the node they both belong to, so only the kind not already carried is read here.
      if (props.anchor.nil? && current == AMPERSAND) || (props.tag.nil? && current == BANG)
        # Properties carried from an earlier line belong to the node that line introduced. When this
        # line turns out to open a mapping key, the properties written on it are the key's own.
        return parse_block_mapping(indent, props, nil) if !props.empty? && starts_block_mapping?(indent)

        props = parse_properties(props)
        skip_blanks
        raise syntax("A block sequence cannot start on the line its properties are on.") if sequence_entry?

        if current == HASH || current == LF || eof?
          skip_to_end_of_line if current == HASH
          advance if current == LF
          save = mark
          skip_to_content
          if eof? || document_boundary?
            reset(save)
            return build_scalar("", plain: true, props: props)
          end
          if @col == parent_indent && allows_zero_indent_sequence?(parent) && sequence_entry?
            return parse_block_sequence(@col, props)
          end
          if @col <= parent_indent
            reset(save)
            return build_scalar("", plain: true, props: props)
          end

          return parse_node_here(@col, parent_indent, props, parent: parent)
        end
        if current == PIPE || current == GREATER
          return build_scalar(parse_block_scalar(parent_indent), plain: false, props: props, block: true)
        end

        return parse_node_here(indent, parent_indent, props, parent: parent, props_on_key_line: true)
      end

      if current == PIPE || current == GREATER
        return build_scalar(parse_block_scalar(parent_indent), plain: false, props: props, block: true)
      end
      return parse_block_sequence(indent, props) if sequence_entry?
      if starts_block_mapping?(indent, tag: props.tag)
        raise syntax("A tab cannot indent a block collection.") if tab

        return parse_block_mapping(indent, props, props_on_key_line ? props : nil)
      end

      parse_flow_node(parent_indent, :flow_out, props).first
    end

    # MARK: block collections

    def starts_block_mapping?(indent, tag: nil)
      # A ':' where a node may start, with nothing before it, is a mapping entry whose key was
      # omitted rather than the start of a plain scalar.
      return true if explicit_key? || explicit_value?

      save = mark
      saved_nodes = @budget.nodes
      saved_aliases = @budget.aliases
      saved_deepest = @deepest
      # The probed text belongs to this node either way, whether it turns out to be a mapping key or
      # the scalar itself, so a tag already read for it applies here too. Without it, a numeric-looking
      # scalar tagged !!str would run the digit guard meant for a plain number the probe never resolves.
      # Only a tag that cannot itself change the probe's answer is worth carrying in; a tag such as
      # !!map genuinely belongs to the mapping as a whole rather than to the key text being probed, and
      # forcing it onto that text here would raise on it before the caller gets to tell the two apart.
      probe_props = PROBE_SAFE_TAGS.include?(tag) ? Props.new(nil, tag) : NO_PROPS
      opens =
        begin
          _key, json_like = parse_flow_node(indent, :block_key, probe_props)
          skip_blanks
          current == COLON && (json_like || blank_or_break?(at(1)))
        rescue ParseError => e
          # A bound crossed while probing is the answer whichever shape the text turns out to have,
          # so it carries its own class out to the caller. Reading it as "this is not a mapping"
          # would report a refusal on size as text that read badly.
          raise if e.limit?

          false
        end
      reset(save)
      # Probing must leave no trace: the same key is parsed again for real, and a probe that failed
      # partway through would otherwise leave the levels it reached counted against an anchor and
      # the aliases it followed charged a second time.
      @budget.nodes = saved_nodes
      @budget.aliases = saved_aliases
      @deepest = saved_deepest
      opens
    end

    def parse_block_mapping(indent, props, first_key_props = nil)
      raise syntax("A tab cannot indent a block collection.") if indentation_has_tab?

      frame = enter_collection
      shape = nil
      members = {}
      # Properties written before an implicit key belong to that key, so a mapping reached through
      # them must not claim them for itself.
      key_props = first_key_props || NO_PROPS
      collection_props = first_key_props.nil? ? props : NO_PROPS

      begin
        count_node
        loop do
          key = nil
          value = nil

          if explicit_key?
            advance
            key = parse_node_value(indent, :explicit_key)
            save = mark
            skip_to_content
            if !eof? && @col == indent && explicit_value? && !document_boundary?
              advance
              value = parse_node_value(indent, :explicit_value)
            else
              reset(save)
            end
          elsif explicit_value?
            # The key was omitted entirely: any anchor or tag written before the ':' belongs to that
            # missing key, the same as an empty node anywhere else.
            key = build_scalar("", plain: true, props: key_props)
            key_props = NO_PROPS
            advance
            value = parse_node_value(indent, :mapping_value)
          else
            key, json_like = parse_flow_node(indent, :block_key, key_props)
            key_props = NO_PROPS
            skip_blanks
            unless current == COLON && (json_like || blank_or_break?(at(1)))
              raise syntax("Expected ':' after a mapping key.")
            end

            advance
            value = parse_node_value(indent, :mapping_value)
          end

          record(key, value, members)

          save = mark
          skip_to_content
          if eof? || document_boundary? || @col < indent
            reset(save)
            break
          end
          raise syntax("Line is indented past the mapping it belongs to.") if @col > indent

          if sequence_entry?
            reset(save)
            break
          end
          raise syntax("Expected another mapping key at this indentation.") unless
            explicit_key? || starts_block_mapping?(indent)
        end
      ensure
        shape = leave_collection(frame)
      end

      finish_collection(collection_props, members, shape)
    end

    def record(key, value, members)
      if members.key?(key)
        case @limits.duplicate_keys
        when :reject
          raise DuplicateKeyError.new("Mapping repeats the key #{key.inspect}.", line: @line)
        when :first_wins
          return
        end
      end
      members[key] = value
    end

    def parse_block_sequence(indent, props)
      raise syntax("A tab cannot indent a block collection.") if indentation_has_tab?

      frame = enter_collection
      shape = nil
      items = []

      begin
        count_node
        loop do
          raise syntax("Expected a '-' sequence entry.") unless sequence_entry?

          advance
          items << parse_node_value(indent, :sequence_item)

          save = mark
          skip_to_content
          if eof? || document_boundary? || @col < indent
            reset(save)
            break
          end
          if @col == indent
            next if sequence_entry?

            reset(save)
            break
          end
          raise syntax("Line is indented past the sequence it belongs to.")
        end
      ensure
        shape = leave_collection(frame)
      end

      finish_collection(props, items, shape)
    end

    # MARK: block scalars

    def parse_block_scalar(parent_indent)
      folded = current == GREATER
      advance

      chomping = nil
      explicit_indent = nil
      while (c = current) && !blank_or_break?(c)
        if c == DASH || c == PLUS
          raise syntax("A block scalar header has one chomping indicator.") if chomping
          chomping = c
        elsif digit?(c) && c != ZERO && explicit_indent.nil?
          explicit_indent = parent_indent + (c - ZERO)
        else
          raise syntax("A block scalar header does not accept '#{[c].pack("U")}'.")
        end
        advance
      end
      skip_blanks
      skip_to_end_of_line if current == HASH
      raise syntax("A block scalar header ends the line.") unless current == LF || eof?

      advance if current == LF

      read_block_body(parent_indent, explicit_indent, folded, chomping)
    end

    def read_block_body(parent_indent, explicit_indent, folded, chomping)
      content_indent = explicit_indent
      lines = []
      leading_empty_indent = 0
      collected = 0
      # Chomping keeps the last line break, and there is none to keep when the input simply stops.
      content_ended_with_break = false

      until eof?
        line_start = mark
        spaces = 0
        while current == SPACE
          spaces += 1
          advance
        end

        if current == LF || eof?
          if content_indent && spaces > content_indent
            # Blank, but indented past the block's content: the indentation up to the content column
            # is not content, and the rest of the run of spaces is a line of that many spaces.
            text = " " * (spaces - content_indent)
            collected += text.length + 1
            check_scalar_length(collected)
            lines << text
            content_ended_with_break = current == LF
          else
            leading_empty_indent = spaces if content_indent.nil? && spaces > leading_empty_indent
            lines << "" if current == LF
          end
          if current == LF
            advance
            next
          end
          break
        end

        if spaces.zero? && document_boundary?
          reset(line_start)
          break
        end
        # A tab where the block's own indentation should be is not indentation and not content
        # either, so the line neither continues the block nor ends it cleanly.
        raise syntax("A tab cannot indent a block scalar's content.") if current == TAB &&
                                                                        spaces < (content_indent || parent_indent + 1)

        if content_indent.nil?
          unless spaces > parent_indent
            reset(line_start)
            break
          end
          unless spaces >= leading_empty_indent
            raise syntax("A leading empty line is indented past the block scalar's content.")
          end

          content_indent = spaces
        end
        if spaces < content_indent
          reset(line_start)
          break
        end

        start = @i
        skip_to_end_of_line
        text = (" " * (spaces - content_indent)) + slice_text(start, @i)
        collected += text.length + 1
        check_scalar_length(collected)
        lines << text
        content_ended_with_break = current == LF
        unless current == LF
          break
        end

        advance
      end

      trailing_empties = 0
      while lines.last == ""
        trailing_empties += 1
        lines.pop
      end

      body = folded ? fold_block_lines(lines) : lines.join("\n")
      check_scalar_length(body.length + trailing_empties)
      chomp_block(body, chomping, trailing_empties, content_ended_with_break)
    end

    def chomp_block(body, chomping, trailing_empties, ended_with_break)
      last_break = ended_with_break && !body.empty? ? "\n" : ""
      case chomping
      when DASH then body
      when PLUS then body + last_break + ("\n" * trailing_empties)
      else body + last_break
      end
    end

    # Folds the lines of a '>' block scalar. A line indented past the content indentation keeps its
    # own line breaks, which is what lets a folded scalar carry a verbatim block.
    def fold_block_lines(lines)
      out = +""
      started = false
      previous = nil
      index = 0

      while index < lines.length
        if lines[index].empty?
          empties = 0
          while index < lines.length && lines[index].empty?
            empties += 1
            index += 1
          end
          break if index >= lines.length

          nxt = lines[index]
          out << if !started
                   "\n" * empties
                 elsif more_indented?(previous) || more_indented?(nxt)
                   "\n" * (empties + 1)
                 else
                   "\n" * empties
                 end
          out << nxt
          previous = nxt
          started = true
          index += 1
          next
        end

        text = lines[index]
        if !started
          out << text
          started = true
        elsif more_indented?(previous) || more_indented?(text)
          out << "\n" << text
        else
          out << " " << text
        end
        previous = text
        index += 1
      end
      out
    end

    def more_indented?(text) = !text.nil? && (text.start_with?(" ") || text.start_with?("\t"))

    # MARK: flow nodes

    # Returns the value and whether it was written in a form the grammar calls JSON-like, which is
    # what lets a ':' follow it with no space.
    def parse_flow_node(parent_indent, context, props)
      # An implicit key has to fit on one line, and a plain scalar is the one node that can quietly
      # run past the end of one, so whether it did is remembered for the caller to check.
      @spanned_lines = false
      if props.empty? && property_start?
        props = parse_properties
        skip_blanks
        skip_flow_separation(parent_indent) if in_flow_brackets?(context)
      end

      c = current
      return [build_scalar("", plain: true, props: props), false] if c.nil?

      # ']', '}' and a line break only ever reach here where a caller already treats an omitted node
      # as valid and skipped this call. A comma does too, but only once an anchor or a tag already
      # read for this node makes it a deliberately empty node rather than a stray comma.
      return [build_scalar("", plain: true, props: props), false] if c == RBRACKET || c == RBRACE || c == LF
      return [build_scalar("", plain: true, props: props), false] if c == COMMA && !props.empty?
      if c == COLON && in_flow_brackets?(context) &&
         (blank_or_break?(at(1)) || at(1) == COMMA || at(1) == RBRACKET || at(1) == RBRACE)
        return [build_scalar("", plain: true, props: props), false]
      end

      case c
      when STAR
        advance
        name = read_name("alias")
        raise syntax("An alias cannot carry an anchor or a tag.") unless props.empty?

        [resolve_alias(name), false]
      when LBRACKET
        [parse_flow_sequence(parent_indent, props), true]
      when LBRACE
        [parse_flow_mapping(parent_indent, props), true]
      when DQUOTE, SQUOTE
        text = parse_quoted(c, parent_indent, single_line: context == :block_key)
        [build_scalar(text, plain: false, props: props), true]
      else
        raise syntax("A plain scalar cannot start with '#{[c].pack("U")}'.") unless plain_first?(c, context)

        [build_scalar(parse_plain_scalar(parent_indent, context), plain: true, props: props), false]
      end
    end

    # Skips white space, comments and line breaks inside a flow collection, raising when the flow
    # hits a document boundary or dedents out of its parent, since both mean it never closed. Returns
    # whether it crossed a line break, which an implicit key may not do before its ':'.
    def skip_flow_separation(parent_indent)
      crossed_line = false
      indent = @col
      loop do
        if @col.zero?
          indent = skip_indentation
          skip_blanks
        else
          skip_blanks
        end
        # A comment needs a space, a tab or a line break before it, the same as anywhere else in the
        # grammar. The preceding character is read straight from the source, since the blank run
        # before a comment can just as well have been consumed as a scalar's trailing edge.
        skip_to_end_of_line if current == HASH && @i.positive? &&
                               (blank?(@src[@i - 1]) || @src[@i - 1] == LF)
        if current == LF
          advance
          crossed_line = true
          next
        end
        break
      end
      return false unless crossed_line

      raise syntax("Flow collection is not closed.") if eof?
      raise syntax("Flow collection is not closed before the document ends.") if document_boundary?
      raise syntax("Flow collection is not closed at this indentation.") if indent <= parent_indent

      true
    end

    def parse_flow_sequence(parent_indent, props)
      frame = enter_collection
      shape = nil
      items = []

      begin
        count_node
        advance
        skip_flow_separation(parent_indent)
        loop do
          if current == RBRACKET
            advance
            break
          end
          if current == QUESTION && blank_or_break?(at(1))
            items << parse_flow_pair(parent_indent)
          else
            entry, json_like = parse_flow_node(parent_indent, :flow_in, NO_PROPS)
            crossed = @spanned_lines
            crossed = skip_flow_separation(parent_indent) || crossed
            if current == COLON &&
               (json_like || blank_or_break?(at(1)) || at(1) == COMMA || at(1) == RBRACKET)
              # A pair written inside a flow sequence reaches its ':' through s-separate-in-line,
              # which is white space on one line, unlike the same pair inside a flow mapping.
              raise syntax("A flow sequence's pair needs its ':' on the key's own line.") if crossed

              advance
              skip_flow_separation(parent_indent)
              value =
                if current == COMMA || current == RBRACKET
                  nil
                else
                  parse_flow_node(parent_indent, :flow_in, NO_PROPS).first
                end
              count_node
              items << { entry => value }
            else
              items << entry
            end
          end

          skip_flow_separation(parent_indent)
          c = current
          raise syntax("Flow sequence is not closed.") if c.nil?

          if c == COMMA
            advance
            skip_flow_separation(parent_indent)
            next
          end
          if c == RBRACKET
            advance
            break
          end
          raise syntax("Expected ',' or ']' in a flow sequence.")
        end
      ensure
        shape = leave_collection(frame)
      end

      finish_collection(props, items, shape)
    end

    # A single pair written with '?' inside a flow sequence, which the grammar makes a one-entry
    # mapping rather than an entry of the sequence it sits in.
    def parse_flow_pair(parent_indent)
      advance
      skip_flow_separation(parent_indent)
      key = nil
      unless current == COLON || current == COMMA || current == RBRACKET || current == RBRACE
        key = parse_flow_node(parent_indent, :flow_key, NO_PROPS).first
      end
      skip_flow_separation(parent_indent)
      value = nil
      if current == COLON
        advance
        skip_flow_separation(parent_indent)
        unless current == COMMA || current == RBRACKET || current == RBRACE
          value = parse_flow_node(parent_indent, :flow_in, NO_PROPS).first
        end
      end
      count_node
      { key => value }
    end

    def parse_flow_mapping(parent_indent, props)
      frame = enter_collection
      shape = nil
      members = {}

      begin
        count_node
        advance
        skip_flow_separation(parent_indent)
        loop do
          if current == RBRACE
            advance
            break
          end

          key = nil
          json_like = false
          explicit = false

          if current == QUESTION && blank_or_break?(at(1))
            advance
            explicit = true
            skip_flow_separation(parent_indent)
          end
          unless current == COLON || current == COMMA || current == RBRACE
            key, json_like = parse_flow_node(parent_indent, explicit ? :flow_in : :flow_key, NO_PROPS)
          end
          skip_flow_separation(parent_indent)

          value = nil
          if current == COLON &&
             (json_like || explicit || blank_or_break?(at(1)) || at(1) == COMMA || at(1) == RBRACE)
            advance
            skip_flow_separation(parent_indent)
            unless current == COMMA || current == RBRACE
              value = parse_flow_node(parent_indent, :flow_in, NO_PROPS).first
            end
            skip_flow_separation(parent_indent)
          end

          record(key, value, members)

          c = current
          raise syntax("Flow mapping is not closed.") if c.nil?

          if c == COMMA
            advance
            skip_flow_separation(parent_indent)
            next
          end
          if c == RBRACE
            advance
            break
          end
          raise syntax("Expected ',' or '}' in a flow mapping.")
        end
      ensure
        shape = leave_collection(frame)
      end

      finish_collection(props, members, shape)
    end

    def in_flow_brackets?(context) = context == :flow_in || context == :flow_key

    def plain_first?(c, context)
      case c
      when DASH, QUESTION, COLON
        nxt = at(1)
        return false if nxt.nil? || blank_or_break?(nxt)
        return false if in_flow_brackets?(context) &&
                        [COMMA, LBRACKET, RBRACKET, LBRACE, RBRACE].include?(nxt)

        true
      when COMMA, LBRACKET, RBRACKET, LBRACE, RBRACE, HASH, AMPERSAND, STAR, BANG, PIPE, GREATER,
           SQUOTE, DQUOTE, PERCENT, AT, BACKTICK, LF, SPACE, TAB
        false
      else
        true
      end
    end

    # MARK: scalars

    def parse_plain_scalar(parent_indent, context)
      out = +""
      separator = ""
      started = false
      length = 0

      loop do
        segment = read_plain_segment(context)
        if started
          out << separator
          length += separator.length
        end
        out << segment
        length += segment.length
        started = true
        check_scalar_length(length)

        break if context == :block_key

        save = mark
        breaks, indent = skip_folded_breaks
        if breaks.zero? || eof? || document_boundary? || indent <= parent_indent || current == HASH
          reset(save)
          break
        end
        if in_flow_brackets?(context) && [COMMA, RBRACKET, RBRACE].include?(current)
          reset(save)
          break
        end

        # A '-' or '?' here reads as an indicator only at the enclosing block's own indentation. Past
        # the column check above this line is already more indented than that, so either one is more
        # scalar text like any other character.
        @spanned_lines = true
        separator = breaks == 1 ? " " : "\n" * (breaks - 1)
      end
      trim_trailing_blanks(out)
    end

    def read_plain_segment(context)
      source = @src
      index = @i
      flow = in_flow_brackets?(context)
      while (c = source[index])
        break if c == LF
        break if c == HASH && (index > @i && (source[index - 1] == SPACE || source[index - 1] == TAB))

        if c == COLON
          nxt = source[index + 1]
          break if blank_or_break?(nxt)
          break if flow && (nxt == COMMA || nxt == LBRACKET || nxt == RBRACKET ||
                            nxt == LBRACE || nxt == RBRACE)
        end
        if flow && (c == COMMA || c == LBRACKET || c == RBRACKET || c == LBRACE || c == RBRACE)
          break
        end

        index += 1
      end
      text = slice_text(@i, index)
      @col += index - @i
      @i = index
      trim_trailing_blanks(text)
    end

    def trim_trailing_blanks(text)
      return text unless text.end_with?(" ", "\t")

      text.sub(/[ \t]+\z/, "")
    end

    # Trims trailing blanks, but never past the first keep characters. A quoted scalar's escape can
    # resolve to a space or a tab right at the end of a line, and that character is content rather
    # than the line's own white space, so folding has to leave it alone.
    def trim_trailing_blanks_keeping(text, keep)
      stop = text.length
      stop -= 1 while stop > keep && (text[stop - 1] == " " || text[stop - 1] == "\t")
      stop == text.length ? text : text[0, stop]
    end

    def parse_quoted(quote, parent_indent, single_line: false)
      advance
      out = +""
      separator = ""
      started = false
      segment = +""
      segment_length = 0
      escaped_join = false
      length = 0
      escaped_length = 0

      flush = lambda do
        if started && !escaped_join
          out << separator
          length += separator.length
        end
        out << segment
        length += segment_length
        started = true
        escaped_join = false
        segment = +""
        segment_length = 0
        escaped_length = 0
        check_scalar_length(length)
      end

      loop do
        c = current
        raise syntax("Quoted scalar is not closed before the input ends.") if c.nil?

        if c == LF
          raise syntax("An implicit key needs to be on one line.") if single_line

          segment = if quote == DQUOTE
                      trim_trailing_blanks_keeping(segment, escaped_length)
                    else
                      trim_trailing_blanks(segment)
                    end
          segment_length = segment.length
          flush.call
          breaks, indent = skip_folded_breaks
          raise syntax("Quoted scalar is not closed before the input ends.") if eof?
          raise syntax("Quoted scalar runs into a document marker.") if document_boundary?
          # A continuation has to clear the node's own parent, or the text below is a sibling of it
          # rather than more of the same scalar.
          raise syntax("Quoted scalar continues at or before its parent's indentation.") if indent <= parent_indent

          separator = breaks == 1 ? " " : "\n" * (breaks - 1)
          next
        end

        if quote == SQUOTE
          if c == SQUOTE
            if at(1) == SQUOTE
              # A String, not the SQUOTE codepoint: appending an Integer here does not amortize like
              # a String append does, so a scalar with many '' pairs would pay for its own length
              # again on every one of them.
              segment << "'"
              segment_length += 1
              advance_n(2)
              next
            end
            advance
            flush.call
            return out
          end
          start = @i
          scan_plain_run(SQUOTE)
          segment << slice_text(start, @i)
          segment_length += @i - start
          next
        end

        if c == BACKSLASH
          advance
          escape = current
          raise syntax("A double-quoted scalar ends with a stray backslash.") if escape.nil?

          if escape == LF
            raise syntax("An implicit key needs to be on one line.") if single_line

            advance
            skip_blanks
            unless current == LF || eof?
              raise syntax("Quoted scalar runs into a document marker.") if document_boundary?
              raise syntax("Quoted scalar does not clear its parent's indentation.") if leading_spaces <= parent_indent
            end
            flush.call
            escaped_join = true
            separator = ""
            next
          end
          resolved = read_escape(escape)
          segment << resolved
          segment_length += resolved.length
          escaped_length = segment_length
          next
        end
        if c == DQUOTE
          advance
          flush.call
          return out
        end

        start = @i
        scan_plain_run(DQUOTE)
        segment << slice_text(start, @i)
        segment_length += @i - start
      end
    end

    # Runs the cursor to the next character the quoted reader has to look at, so an ordinary run of
    # text costs one slice rather than one call per character.
    def scan_plain_run(quote)
      source = @src
      index = @i
      while (c = source[index]) && c != LF && c != quote && !(quote == DQUOTE && c == BACKSLASH)
        index += 1
      end
      @col += index - @i
      @i = index
    end

    ESCAPES = {
      0x30 => "\0", 0x61 => "\a", 0x62 => "\b", 0x74 => "\t", TAB => "\t", 0x6E => "\n",
      0x76 => "\v", 0x66 => "\f", 0x72 => "\r", 0x65 => "\e", SPACE => " ", DQUOTE => "\"",
      SLASH => "/", BACKSLASH => "\\", 0x4E => "\u0085", 0x5F => "\u00A0",
      0x4C => "\u2028", 0x50 => "\u2029"
    }.freeze

    HEX_ESCAPE_WIDTHS = { 0x78 => 2, 0x75 => 4, 0x55 => 8 }.freeze

    def read_escape(escape)
      advance
      resolved = ESCAPES[escape]
      return resolved if resolved

      width = HEX_ESCAPE_WIDTHS[escape]
      return read_hex_escape(width) if width

      raise syntax("A double-quoted scalar does not accept the escape '\\#{[escape].pack("U")}'.")
    end

    def read_hex_escape(digits)
      value = 0
      digits.times do
        c = current
        digit = hex_value(c)
        raise syntax("A '\\x', '\\u' or '\\U' escape needs #{digits} hex digits.") if digit.nil?

        value = (value * 16) + digit
        advance
      end
      if value > MAX_CODEPOINT || SURROGATES.cover?(value)
        raise syntax("Escape '\\#{format("%04X", value)}' is not a unicode scalar value.")
      end

      value.chr(Encoding::UTF_8)
    end

    def hex_value(c)
      return nil if c.nil?
      return c - 0x30 if c >= 0x30 && c <= 0x39
      return (c - 0x61) + 10 if c >= 0x61 && c <= 0x66
      return (c - 0x41) + 10 if c >= 0x41 && c <= 0x46

      nil
    end

    # MARK: building values

    def build_scalar(text, plain:, props: NO_PROPS, block: false)
      count_node
      check_scalar_length(text.length)
      check_printable(text) if plain || block
      tag = props.tag
      check_number_digits(text) if NUMERIC_TAGS.include?(tag) || (plain && !NON_NUMERIC_TAGS.include?(tag))
      resolved = Tag.resolve_scalar(text, plain: plain && !block, tag: tag, line: @line)
      remember_anchor(props.anchor, resolved, 1, 1) if props.anchor
      resolved
    end

    def finish_collection(props, value, shape)
      resolved = Tag.resolve_collection(value, tag: props.tag, line: @line)
      remember_anchor(props.anchor, resolved, shape[0], shape[1]) if props.anchor
      resolved
    end

    def remember_anchor(name, value, nodes, depth)
      @anchors[name] = Anchor.new(value, nodes, depth)
    end

    # An alias shares the value its anchor named rather than copying it, so the tree a stream builds
    # can hold the same object in several places.
    def resolve_alias(name)
      anchor = @anchors[name]
      unless anchor
        raise UndefinedAliasError.new("Alias '*#{name}' names an anchor that has not been defined.",
                                      line: @line)
      end

      @budget.aliases += 1
      unless @budget.aliases <= @limits.max_alias_expansions
        raise TooManyAliasesError.new(
          "Stream dereferences more than #{@limits.max_alias_expansions} aliases.", line: @line
        )
      end
      # An alias drops a whole subtree in at this point, so it can build a value deeper than the
      # parser's own recursion ever went. The bound has to cover that as well as the stack.
      if @depth + anchor.depth > @depth_ceiling
        raise DepthExceededError.new(
          "Alias '*#{name}' would nest deeper than the limit of #{@depth_ceiling}.", line: @line
        )
      end

      reached = @depth + anchor.depth - 1
      @deepest = reached if reached > @deepest
      count_node(anchor.nodes)
      anchor.value
    end
  end
end
