# frozen_string_literal: true

module YAMLCamel
  module IO
    # The contract for compressing and decompressing a YAML body.
    #
    # The default is gzip over Ruby's own Zlib. Anything that answers these methods can stand in its
    # place, which is what lets a caller use a codec of its own on both ends of a transfer.
    #
    # #decompressor is the one that matters for hostile input: it bounds the output while inflating
    # rather than after, so a small body that expands without end is refused partway through.
    module Compression
      # The token this codec is named by in a Content-Encoding header.
      def content_encoding
        raise NotImplementedError, "#{self.class} does not implement #content_encoding"
      end

      # True when the bytes carry this codec's own signature. A signature proves nothing about the
      # rest of the body, so treat it as a hint rather than as validation.
      def compressed?(_bytes)
        raise NotImplementedError, "#{self.class} does not implement #compressed?"
      end

      def compress(_bytes, level: nil)
        raise NotImplementedError, "#{self.class} does not implement #compress"
      end

      # Decompresses the whole body. Raises InflatedTooLargeError as soon as the output crosses
      # max_output_bytes.
      def decompress(bytes, max_output_bytes: nil)
        worker = decompressor(max_output_bytes: max_output_bytes)
        worker.push(bytes) + worker.finish
      end

      # Returns an object answering #push(bytes) and #finish, both returning decompressed bytes.
      def decompressor(max_output_bytes: nil)
        raise NotImplementedError, "#{self.class} does not implement #decompressor"
      end
    end

    # Gzip over Ruby's Zlib. Reads both gzip and zlib wrappers, and writes gzip.
    class GzipCompression
      include Compression

      MAGIC = "\x1F\x8B".b

      # 32 turns on Zlib's own header detection, so a body wrapped either way reads back.
      WINDOW_BITS = 15 + 32

      # Gzip's own window plus the header, which is what tells Zlib to write a gzip wrapper.
      DEFLATE_WINDOW_BITS = 15 + 16

      def initialize
        require "zlib"
      end

      def content_encoding = "gzip"

      def compressed?(bytes)
        !bytes.nil? && bytes.bytesize >= 2 && bytes.b.byteslice(0, 2) == MAGIC
      end

      def compress(bytes, level: nil)
        deflate = Zlib::Deflate.new(level || Zlib::DEFAULT_COMPRESSION, DEFLATE_WINDOW_BITS)
        begin
          deflate.deflate(bytes.b, Zlib::FINISH)
        ensure
          deflate.close
        end
      rescue Zlib::Error => e
        raise CompressionError, "gzip could not compress the body: #{e.message}"
      end

      def decompressor(max_output_bytes: nil)
        Decompressor.new(max_output_bytes: max_output_bytes)
      end

      # Inflates a gzip body a chunk at a time, refusing one that expands past its bound.
      class Decompressor
        attr_reader :output_bytes

        def initialize(max_output_bytes: nil)
          require "zlib"
          @limit = max_output_bytes
          @output_bytes = 0
          @inflate = Zlib::Inflate.new(WINDOW_BITS)
          @finished = false
          @members = 0
        end

        def push(bytes)
          return "" if bytes.nil? || bytes.empty?
          raise CompressionError, "the gzip stream is already finished." if @finished

          # Zlib hands the output over a chunk at a time when it is given a block, which is what
          # gives the bound something to measure while the body is still inflating. Inflating the
          # whole argument in one call puts all of a bomb in memory before the first check runs.
          out = +""
          out.force_encoding(Encoding::ASCII_8BIT)
          remaining = bytes.b
          until remaining.empty?
            @inflate ||= Zlib::Inflate.new(WINDOW_BITS)
            @inflate.inflate(remaining) do |chunk|
              count(chunk)
              out << chunk
            end
            break unless @inflate.finished?

            # Once finished, Zlib#finish returns unused *compressed input*, not decoded output.
            # It may start another gzip member, but must never be appended to the YAML text.
            remaining = @inflate.finish
            @inflate.close
            @inflate = nil
            @members += 1
          end
          out
        rescue Zlib::Error => e
          raise CompressionError, "gzip could not inflate the body: #{e.message}"
        end

        def finish
          return "" if @finished

          @finished = true
          if @inflate || @members.zero?
            @inflate.close if @inflate && !@inflate.closed?
            raise CompressionError, "the gzip stream ends before its trailer."
          end

          ""
        rescue Zlib::Error => e
          raise CompressionError, "gzip could not finish the body: #{e.message}"
        end

        private

        def count(out)
          @output_bytes += out.bytesize
          return if @limit.nil? || @output_bytes <= @limit

          @inflate.close if @inflate && !@inflate.closed?
          raise InflatedTooLargeError,
                "the body inflates past the #{@limit} byte limit."
        end
      end
    end
  end
end
