# frozen_string_literal: true

module YAMLCamel
  # Reads and writes YAML on disk, plain or compressed.
  #
  # Every call takes a storage and a compression, both defaulting to the local filesystem and gzip.
  # Pass your own to route the same calls through an asset bundle, an object store or a codec of your
  # own: see YAMLCamel::IO::Storage and YAMLCamel::IO::Compression for the contracts.
  module Files
    # How many bytes to hold before deciding whether a body is compressed.
    SNIFF_BYTES = 8

    # Guards the lazy defaults below against being built twice by two threads racing on the first
    # call. Set once at load time so the guard itself needs no guarding.
    DEFAULTS_MUTEX = Mutex.new
    private_constant :DEFAULTS_MUTEX

    class << self
      # Meant for one-time setup, generally at boot: reassigning either while other threads may
      # already be reading it races the same way any shared global does.
      attr_writer :storage, :compression

      def storage = @storage || DEFAULTS_MUTEX.synchronize { @storage ||= IO::FileStorage.new }

      def compression = @compression || DEFAULTS_MUTEX.synchronize { @compression ||= IO::GzipCompression.new }
    end

    module_function

    # Reads the first document of a file, or nil for a file with no documents. compressed: :auto
    # reads a compressed file when the bytes carry the codec's signature, true always decompresses,
    # false never does.
    def load(path, compressed: :auto, limits: Limits.default, transfer: IO::TransferLimits.default,
             chunk_size: 64 * 1024, storage: Files.storage, compression: Files.compression)
      load_stream(path, compressed: compressed, limits: limits, transfer: transfer,
                        chunk_size: chunk_size, storage: storage, compression: compression).first
    end

    # Reads every document of a file, in order.
    def load_stream(path, compressed: :auto, limits: Limits.default,
                    transfer: IO::TransferLimits.default, chunk_size: 64 * 1024,
                    storage: Files.storage, compression: Files.compression)
      documents = []
      each_document(path, compressed: compressed, limits: limits, transfer: transfer,
                          chunk_size: chunk_size, storage: storage, compression: compression) do |document|
        documents << document
      end
      documents
    end

    # Reads a file document by document, yielding each one as it completes, and returns how many
    # there were. Read and, when compressed, inflated in chunks, so neither the whole text nor every
    # value is ever held at once.
    def each_document(path, compressed: :auto, limits: Limits.default,
                      transfer: IO::TransferLimits.default, chunk_size: 64 * 1024,
                      storage: Files.storage, compression: Files.compression, &block)
      stream = DocumentStream.new(limits: limits, &block)
      decompressor = nil
      inflated_bytes = 0
      # A codec's signature is a few bytes wide, so sniffing waits for enough of them rather than
      # deciding on whatever the first chunk happened to hold.
      pending = compressed == :auto ? +"" : nil
      decompressor = compression.decompressor(max_output_bytes: transfer.max_inflated_bytes) if compressed == true

      # Measures decompressed bytes against transfer.max_inflated_bytes before they reach the
      # stream, rather than trusting an injected Compression to police its own bound: the same
      # reasoning HTTP.decode_body re-checks an already-inflated response body.
      measure_inflated = lambda do |bytes|
        inflated_bytes += bytes.bytesize
        if inflated_bytes > transfer.max_inflated_bytes
          raise InflatedTooLargeError, "the body inflates past the #{transfer.max_inflated_bytes} byte limit."
        end
        bytes
      end

      storage.each_chunk(path, chunk_size: chunk_size) do |chunk|
        if pending
          pending << chunk.b
          next if pending.bytesize < SNIFF_BYTES

          chunk = pending
          pending = nil
          decompressor = compression.decompressor(max_output_bytes: transfer.max_inflated_bytes) if
            compression.compressed?(chunk)
        end
        stream.push(decompressor ? measure_inflated.call(decompressor.push(chunk)) : chunk)
      end
      if pending && !pending.empty?
        decompressor = compression.decompressor(max_output_bytes: transfer.max_inflated_bytes) if
          compression.compressed?(pending)
        stream.push(decompressor ? measure_inflated.call(decompressor.push(pending)) : pending)
      end
      stream.push(measure_inflated.call(decompressor.finish)) if decompressor
      stream.finish
      stream.documents
    end

    # Writes one value as a YAML document. Returns the number of bytes written.
    def dump(path, object, compress: false, sort_keys: false, limits: EmitLimits.default,
             storage: Files.storage, compression: Files.compression)
      write_text(path, YAMLCamel.dump(object, sort_keys: sort_keys, limits: limits),
                 compress: compress, storage: storage, compression: compression)
    end

    # Writes several values as one stream, each with its own '---' marker.
    def dump_stream(path, objects, compress: false, sort_keys: false, limits: EmitLimits.default,
                    storage: Files.storage, compression: Files.compression)
      write_text(path, YAMLCamel.dump_stream(*objects, sort_keys: sort_keys, limits: limits),
                 compress: compress, storage: storage, compression: compression)
    end

    def write_text(path, text, compress:, storage:, compression:)
      bytes = compress ? compression.compress(text) : text
      storage.write(path, bytes)
    end
    private_class_method :write_text
  end

  class << self
    # Reads the first document of a file, the way Psych's own load_file does.
    def load_file(path, **options) = Files.load(path, **options)

    # Writes one value to a file as a YAML document.
    def dump_file(path, object, **options) = Files.dump(path, object, **options)
  end
end
