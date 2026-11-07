# frozen_string_literal: true

module YAMLCamel
  # Reads a byte stream one document at a time, so a stream of many documents never has to be held
  # whole in memory. Bytes go in as they arrive and each document comes out as soon as its text is
  # complete, with every Limits bound applying across the whole stream.
  #
  # A stream belongs to whichever thread first calls #push or #finish: a later call from another
  # thread raises CrossThreadUsageError instead of racing on the shared buffer and parse state. Give
  # each thread its own DocumentStream.
  class DocumentStream
    # A '---' or '...' at the start of a line, with nothing but white space and a comment after it.
    # A construct that spans such a line is refused by the parser, so splitting here is safe.
    START_MARKER = /\A---(?:[ \t].*)?\z/
    END_MARKER = /\A\.\.\.(?:[ \t].*)?\z/

    attr_reader :documents

    # Creates a reader. The block receives each document as it completes.
    def initialize(limits: Limits.default, &block)
      @limits = limits
      @block = block
      @budget = Budget.new
      @buffer = +""
      @buffer.force_encoding(Encoding::ASCII_8BIT)
      @scanned = 0
      @document_start = 0
      @prefix_only = true
      @total_bytes = 0
      @documents = 0
      @owner_thread = nil
      @owner_mutex = Mutex.new
    end

    # Feeds the next chunk of bytes and emits every document they completed.
    def push(bytes)
      check_thread!
      return self if bytes.nil? || bytes.empty?

      @total_bytes += bytes.bytesize
      unless @total_bytes <= @limits.max_input_bytes
        raise InputTooLargeError,
              "Stream is over the #{@limits.max_input_bytes} byte limit."
      end

      @buffer << bytes.b
      scan
      self
    end

    # Signals the end of the input and emits whatever the tail held.
    def finish
      check_thread!
      emit(@buffer.bytesize)
      @document_start = @buffer.bytesize
      compact
      self
    end

    private

    # Claims the stream for the calling thread on first use, and refuses any other thread after
    # that. The claim itself is locked, so two threads racing for first use cannot both win it, the
    # one race this class does still have to guard against directly.
    def check_thread!
      current = Thread.current
      return if @owner_thread.equal?(current)

      @owner_mutex.synchronize do
        @owner_thread ||= current
        return if @owner_thread.equal?(current)
      end

      raise CrossThreadUsageError,
            "DocumentStream was started on #{@owner_thread.inspect} and cannot be used from " \
            "#{current.inspect} too. Give each thread its own stream."
    end

    def scan
      while (line_end = @buffer.index("\n", @scanned))
        line_start = @scanned
        @scanned = line_end + 1
        classify(@buffer.byteslice(line_start, line_end - line_start), line_start, @scanned)
      end
      compact
    end

    def classify(line, line_start, next_start)
      line = line.chomp("\r")

      if START_MARKER.match?(line)
        # Directives, comments and blank lines ahead of a '---' are that document's own prefix, so
        # there is nothing to hand over yet. Anything else before them is content, and it goes to the
        # parser together with them rather than being quietly split away from them.
        unless @prefix_only
          emit(line_start)
          @document_start = line_start
        end
        @prefix_only = false
        return
      end

      if END_MARKER.match?(line)
        emit(next_start)
        @document_start = next_start
        @prefix_only = true
        return
      end

      @prefix_only = false unless prefix_line?(line)
    end

    # A line that may sit between the end of one document and the '---' of the next.
    def prefix_line?(line)
      stripped = line.strip
      stripped.empty? || stripped.start_with?("#", "%")
    end

    # Parses the buffered text up to the given offset as one document and hands it to the block.
    def emit(offset)
      length = offset - @document_start
      return if length <= 0

      text = @buffer.byteslice(@document_start, length)
      Reader.new(text, limits: @limits, budget: @budget).parse_stream.each do |document|
        @documents += 1
        unless @documents <= @limits.max_documents
          raise TooManyDocumentsError, "Stream holds more than #{@limits.max_documents} documents."
        end

        @block&.call(document)
      end
    end

    # Drops what has already been handed over, so the buffer holds the document being read and no
    # more.
    def compact
      return if @document_start.zero?

      @buffer = (@buffer.byteslice(@document_start..) || +"").dup
      @buffer.force_encoding(Encoding::ASCII_8BIT)
      @scanned -= @document_start
      @scanned = 0 if @scanned.negative?
      @document_start = 0
    end
  end

  class << self
    # Reads every document from an IO, a string, or anything that answers #read, yielding each one as
    # it completes, and returns how many there were. Read and parsed in chunks, so a stream larger
    # than memory is fine as long as no single document is.
    def each_document(input, limits: Limits.default, chunk_size: 64 * 1024, &block)
      stream = DocumentStream.new(limits: limits, &block)
      if input.respond_to?(:read)
        while (chunk = input.read(chunk_size))
          # Ruby's own IO answers nil at the end of the input, but an object standing in for one may
          # answer an empty string instead. Reading on would never make progress and never grow the
          # byte total either, so no bound would ever bring the loop to a stop.
          break if chunk.empty?

          stream.push(chunk)
        end
      else
        stream.push(input.to_s)
      end
      stream.finish
      stream.documents
    end
  end
end
